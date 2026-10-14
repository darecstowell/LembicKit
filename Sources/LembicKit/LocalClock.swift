import Foundation

extension Transcript {
    /// The local date and time strings the renderer prints, without a
    /// DateFormatter call per message. Dates with a fractional second or outside years 1000 to 9999 use a
    /// DateFormatter, so the output is always the formatter's.
    final class LocalClock {
        private let timeZone: TimeZone
        private var offset = 0
        private var dayNumber = Int.min
        private var dayText = ""
        private lazy var formatters = (
            day: Transcript.formatter("yyyy-MM-dd", timeZone: timeZone),
            weekday: Transcript.formatter("EEE", timeZone: timeZone),
            time: Transcript.formatter("HH:mm", timeZone: timeZone),
            stamp: Transcript.formatter("yyyy-MM-dd'T'HH:mm:ssxxx", timeZone: timeZone)
        )
        private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        private static let twoDigits = (0..<100).map { $0 < 10 ? "0\($0)" : "\($0)" }

        init(timeZone: TimeZone) { self.timeZone = timeZone }

        /// Local seconds since 1970, or nil when the fast path does not apply.
        private func localSeconds(_ date: Date) -> Int? {
            let t = date.timeIntervalSince1970
            guard t == t.rounded(.down), t > -30_000_000_000, t < 250_000_000_000 else {
                return nil
            }
            offset = timeZone.secondsFromGMT(for: date)
            return Int(t) + offset
        }

        private func days(_ seconds: Int) -> Int {
            seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400
        }

        func day(_ date: Date) -> String {
            guard let seconds = localSeconds(date) else { return formatters.day.string(from: date) }
            let number = days(seconds)
            if number != dayNumber {
                // Days since 1970 to a Gregorian date (H. Hinnant, civil_from_days).
                let z = number + 719_468
                let era = (z >= 0 ? z : z - 146_096) / 146_097
                let doe = z - era * 146_097
                let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
                let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
                let mp = (5 * doy + 2) / 153
                let d = doy - (153 * mp + 2) / 5 + 1
                let m = mp < 10 ? mp + 3 : mp - 9
                let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
                guard (1000...9999).contains(y) else { return formatters.day.string(from: date) }
                dayNumber = number
                dayText = "\(y)-\(Self.twoDigits[m])-\(Self.twoDigits[d])"
            }
            return dayText
        }

        func weekday(_ date: Date) -> String {
            guard let seconds = localSeconds(date) else {
                return formatters.weekday.string(from: date)
            }
            return Self.weekdays[((days(seconds) + 4) % 7 + 7) % 7]
        }

        func time(_ date: Date) -> String {
            guard let seconds = localSeconds(date) else {
                return formatters.time.string(from: date)
            }
            let s = seconds - days(seconds) * 86_400
            return "\(Self.twoDigits[s / 3600]):\(Self.twoDigits[s % 3600 / 60])"
        }

        /// ISO 8601 with the UTC offset, as `yyyy-MM-dd'T'HH:mm:ssxxx`.
        func stamp(_ date: Date) -> String {
            guard let seconds = localSeconds(date), !day(date).isEmpty, dayNumber == days(seconds)
            else { return formatters.stamp.string(from: date) }
            let s = seconds - days(seconds) * 86_400
            let sign = offset < 0 ? "-" : "+"
            let off = abs(offset)
            return "\(dayText)T\(Self.twoDigits[s / 3600]):\(Self.twoDigits[s % 3600 / 60]):"
                + "\(Self.twoDigits[s % 60])\(sign)\(Self.twoDigits[off / 3600]):"
                + Self.twoDigits[off % 3600 / 60]
        }
    }

    /// Each DST fall-back hour between two dates: the instants whose local clock
    /// time happens twice.
    static func repeatedHours(from start: Date, to end: Date, in timeZone: TimeZone)
        -> [Range<Date>]
    {
        var windows: [Range<Date>] = []
        var cursor = start.addingTimeInterval(-86_400)
        while let change = timeZone.nextDaylightSavingTimeTransition(after: cursor),
            change <= end.addingTimeInterval(86_400)
        {
            let before = timeZone.secondsFromGMT(for: change.addingTimeInterval(-1))
            let shift = TimeInterval(before - timeZone.secondsFromGMT(for: change))
            if shift > 0 {
                windows.append(change.addingTimeInterval(-shift)..<change.addingTimeInterval(shift))
            }
            cursor = change
        }
        return windows
    }

    static func formatter(_ format: String, timeZone: TimeZone = .current) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }
}
