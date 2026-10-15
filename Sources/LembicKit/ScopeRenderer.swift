import Foundation

extension Export {
    /// One extracted conversation, kept for fast re-renders as the scope changes. Each
    /// render equals `Export.render(records:...)`; the first one per category set scans
    /// the whole thread, so it costs more than one `Export.render` of a small scope.
    public final class ScopeRenderer: @unchecked Sendable {
        private let records: [MessageRecord]
        private let number: String
        private let group: Transcript.GroupRenderInfo?
        private let systemEvents: [Transcript.SystemEvent]
        private let skipped: [SkippedMessage]
        private let noteToSelf: Bool
        private let named: (conversation: Conversation, labels: [Int64: String])?
        /// Dates never go backwards, so a date window is one index range.
        private let isSorted: Bool

        private let lock = NSLock()
        private var input: DetectorInput?
        private var detections = RecentCache<Set<SecretCategory>, DetectionMemo>()
        private var scrubs = RecentCache<Set<ScrubberCategory>, [[Range<Int>]]>()
        private let stop = StopFlag()

        /// The same inputs `Export.render(records:...)` takes, less the per-render ones.
        /// Records out of date order get no memo: each render runs a full pass, and a
        /// cancel is seen only before and after it.
        public init(
            records: [MessageRecord], number: String,
            group: Transcript.GroupRenderInfo? = nil,
            systemEvents: [Transcript.SystemEvent] = [], skipped: [SkippedMessage] = [],
            noteToSelf: Bool = false
        ) {
            self.records = records
            self.number = number
            self.group = group
            self.systemEvents = systemEvents
            self.skipped = skipped
            self.noteToSelf = noteToSelf
            self.named = nil
            self.isSorted = zip(records, records.dropFirst()).allSatisfy { $0.date <= $1.date }
        }

        /// Renders as the instance `Export.render(_:...)` does for `conversation`:
        /// its identifier, roster, and the names `labels` give its speakers.
        public init(
            records: [MessageRecord], conversation: Conversation, labels: [Int64: String],
            systemEvents: [Transcript.SystemEvent] = [], skipped: [SkippedMessage] = []
        ) {
            self.records = records
            self.number = conversation.primaryIdentifier
            self.group = Export.groupRenderInfo(for: conversation)
            self.systemEvents = conversation.isGroup ? systemEvents : []
            self.skipped = skipped
            self.noteToSelf = conversation.isNoteToSelf
            self.named = (conversation, labels)
            self.isSorted = zip(records, records.dropFirst()).allSatisfy { $0.date <= $1.date }
        }

        /// Shuts the renderer down: a pass in progress stops and every later render throws.
        public func cancel() { stop.set() }

        /// `Export.render(records:...)` for one scope. Throws `CancellationError` when its
        /// task or the renderer is cancelled; memos already built stay. A first pass holds
        /// a lock, so a render that needs another category set waits for it.
        public func render(
            formats: Set<Format> = [.txt], scope: Scope = .all,
            redactions: RedactionSet = RedactionSet(), detect: Bool = true
        ) throws -> Rendered {
            try withUnsafeCurrentTask { task in
                // The task outlives this call, so its cancel flag is safe to poll from workers.
                let call = StopFlag(parent: stop, task: task.map(TaskProbe.init))
                return try render(
                    formats: formats, scope: scope, redactions: redactions, detect: detect,
                    stop: call)
            }
        }

        private func render(
            formats: Set<Format>, scope: Scope, redactions: RedactionSet, detect: Bool,
            stop: StopFlag
        ) throws -> Rendered {
            if stop.isSet { throw CancellationError() }
            var scope = scope
            if let named {
                scope = Export.named(scope, conversation: named.conversation, labels: named.labels)
            }
            let bounds = isSorted ? indices(scope.dateRange) : nil
            let filtered =
                bounds.map { Array(records[$0]) } ?? Export.unredactedRecords(records, scope: scope)
            var failure: Error?
            let rendered = Export.render(
                filtered: filtered, number: number, formats: formats, scope: scope,
                redactions: redactions, group: group, systemEvents: systemEvents,
                skipped: skipped, noteToSelf: noteToSelf,
                detected: {
                    guard detect else { return [] }
                    guard let bounds else {
                        return SecretDetector.detect(in: filtered, enabled: scope.enabledDetectors)
                    }
                    do {
                        return try detected(in: bounds, enabled: scope.enabledDetectors, stop: stop)
                    } catch {
                        failure = error
                        return []
                    }
                },
                scrubbed: {
                    guard let bounds else { return Export.scrubbed(filtered, scope: scope) }
                    do {
                        return try scrubbed(
                            in: bounds, categories: scope.enabledScrubbers, stop: stop)
                    } catch {
                        failure = error
                        return RedactionSet()
                    }
                })
            if let failure { throw failure }
            if stop.isSet { throw CancellationError() }
            return rendered
        }

        /// The records `range` keeps, as one index range (records are in date order).
        private func indices(_ range: ClosedRange<Date>?) -> Range<Int> {
            guard let range else { return records.indices }
            let lo = firstIndex { $0.date >= range.lowerBound }
            let hi = firstIndex { $0.date > range.upperBound }
            return lo..<Swift.max(lo, hi)
        }

        /// The first index where `pass` holds, for a `pass` that stays true once true.
        private func firstIndex(where pass: (MessageRecord) -> Bool) -> Int {
            var lo = 0
            var hi = records.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if pass(records[mid]) { hi = mid } else { lo = mid + 1 }
            }
            return lo
        }

        // MARK: - Memoized detectors and scrubbers

        private func detected(
            in bounds: Range<Int>, enabled: Set<SecretCategory>, stop: StopFlag
        ) throws
            -> [DetectedSecret]
        {
            guard !enabled.isEmpty, !bounds.isEmpty else { return [] }
            let (memo, input) = try lock.withLock { () throws -> (DetectionMemo, DetectorInput) in
                let input = try self.input ?? buildInput(stop: stop)
                self.input = input
                if let memo = detections.value(for: enabled) { return (memo, input) }
                let memo = try DetectionMemo(input, enabled: enabled, stop: stop)
                detections.insert(memo, for: enabled)
                return (memo, input)
            }
            return memo.detected(in: bounds, input: input, enabled: enabled)
        }

        private func buildInput(stop: StopFlag) throws -> DetectorInput {
            let records = self.records
            let parts = try parallelMap(records.count, stop: stop) {
                i -> (NormalizedText?, TextProfile?) in
                guard records[i].guid != nil else { return (nil, nil) }
                let body = TextNormalizer.normalize(records[i].text)
                return (body, TextProfile(body.text))
            }
            return DetectorInput(
                records: records, bodies: parts.map(\.0), profiles: parts.map(\.1), gated: true)
        }

        private func scrubbed(
            in bounds: Range<Int>, categories: Set<ScrubberCategory>, stop: StopFlag
        ) throws
            -> RedactionSet
        {
            var set = RedactionSet()
            guard !categories.isEmpty, !bounds.isEmpty else { return set }
            let ranges = try lock.withLock { () throws -> [[Range<Int>]] in
                if let ranges = scrubs.value(for: categories) { return ranges }
                let records = self.records
                let ranges = try parallelMap(records.count, stop: stop) { i in
                    records[i].guid == nil
                        ? []
                        : SecretScrubber.ranges(
                            in: records[i].text as NSString, categories: categories)
                }
                scrubs.insert(ranges, for: categories)
                return ranges
            }
            for i in bounds {
                guard let guid = records[i].guid else { continue }
                for range in ranges[i] { set.add(Redaction(guid: guid, range: range)) }
            }
            return set
        }
    }
}

/// Each detector piece found once over the whole thread. A scope reuses a piece
/// only when the piece read nothing outside the scope; the rest run again inside it.
struct DetectionMemo: @unchecked Sendable {
    private let single: [[DetectedSecret]]
    private let joinedEnd: [Int]
    private let joined: [[DetectedSecret]]
    private let answers: [DetectedSecret?]
    private let keyLast: [Int]
    private let keyBlocks: [[DetectedSecret]]

    init(
        _ input: DetectorInput, enabled: Set<SecretCategory>, stop: StopFlag
    ) throws {
        let n = input.records.count
        let all = 0..<n
        single = try parallelMap(n, stop: stop) { input.single($0, from: 0, enabled: enabled) }
        if !DetectorInput.joinRules(enabled).isEmpty {
            let pieces = try parallelMap(n, stop: stop) { i -> (end: Int, hits: [DetectedSecret]) in
                i + 1 < n ? input.joined(i, in: all, enabled: enabled) : (n, [])
            }
            joinedEnd = pieces.map(\.end)
            joined = pieces.map(\.hits)
        } else {
            (joinedEnd, joined) = ([], [])
        }
        answers =
            enabled.contains(.password) || enabled.contains(.standingCode)
            ? try parallelMap(n, stop: stop) { i in
                i + 1 < n ? input.answer(i, enabled: enabled) : nil
            } : []
        if enabled.contains(.apiKey) {
            let pieces = try parallelMap(n, stop: stop) { input.keyBlock($0, upTo: n) }
            keyLast = pieces.map(\.last)
            keyBlocks = pieces.map(\.hits)
        } else {
            (keyLast, keyBlocks) = ([], [])
        }
    }

    /// The same flags `SecretDetector.detect` finds over `input.records[bounds]`.
    func detected(in bounds: Range<Int>, input: DetectorInput, enabled: Set<SecretCategory>)
        -> [DetectedSecret]
    {
        let lo = bounds.lowerBound
        let hi = bounds.upperBound
        // The first record of a scope has no message before it, unless the thread starts there.
        return input.assemble(
            bounds, enabled: enabled,
            single: { i in
                i == lo && lo > 0 ? input.single(i, from: lo, enabled: enabled) : single[i]
            },
            joined: { i in
                (i == lo && lo > 0) || joinedEnd[i] > hi
                    ? input.joined(i, in: bounds, enabled: enabled).hits : joined[i]
            },
            answer: { answers[$0] },
            keyBlock: { i in
                keyLast[i] >= hi ? input.keyBlock(i, upTo: hi).hits : keyBlocks[i]
            })
    }
}

/// `(0..<count).map(transform)` on every core, in chunks. Throws
/// `CancellationError` when `stop` turns true.
func parallelMap<T>(
    _ count: Int, stop: StopFlag, _ transform: @Sendable (Int) -> T
) throws -> [T] {
    let chunk = 256
    var out = [T?](repeating: nil, count: count)
    out.withUnsafeMutableBufferPointer { buffer in
        let slots = ParallelSlots(buffer: buffer)
        DispatchQueue.concurrentPerform(iterations: (count + chunk - 1) / chunk) { c in
            if stop.isSet { return }
            for i in (c * chunk)..<Swift.min(count, (c + 1) * chunk) {
                slots.buffer[i] = transform(i)
            }
        }
    }
    if stop.isSet { throw CancellationError() }
    return out.map { $0! }
}

/// Each chunk writes only its own slots.
private struct ParallelSlots<T>: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<T?>
}

/// A stop flag; it also reads as set when its parent is set or its task is cancelled.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private let parent: StopFlag?
    private let task: TaskProbe?
    init(parent: StopFlag? = nil, task: TaskProbe? = nil) {
        self.parent = parent
        self.task = task
    }
    func set() { lock.withLock { value = true } }
    var isSet: Bool {
        lock.withLock { value } || (task?.task.isCancelled ?? false) || (parent?.isSet ?? false)
    }
}

/// The calling task, read only while that task's synchronous render runs.
struct TaskProbe: @unchecked Sendable {
    let task: UnsafeCurrentTask
}

/// The few most recently used values; the oldest is dropped past `limit`.
struct RecentCache<Key: Hashable, Value> {
    private var entries: [(key: Key, value: Value)] = []
    let limit = 4

    mutating func value(for key: Key) -> Value? {
        guard let i = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: i)
        entries.append(entry)
        return entry.value
    }

    mutating func insert(_ value: Value, for key: Key) {
        entries.removeAll { $0.key == key }
        entries.append((key, value))
        if entries.count > limit { entries.removeFirst() }
    }
}
