# LembicKit

LembicKit reads a macOS Messages `chat.db` (SQLite), folds its rows into people-level conversations, and renders LLM-ready transcripts: a compact daily-grouped `.txt` and one JSON object per message (`.jsonl`). It also runs on-device detection of high-harm secrets and reversible redaction over the same message bodies. The package ships a library target (`LembicKit`) and a command-line tool (`lembic-cli`). It targets macOS 14 (Sonoma) and never touches the live Messages store: it copies `chat.db` (and its `-wal`/`-shm` sidecars) to a private temp directory and reads the copy read-only.

## Domain glossary

These are the core nouns, drawn from the actual type names.

**Conversation** (`Conversation.swift`). One person or one group, after row-level chats are folded together. A 1:1 conversation is the union of every `style=45` chat that belongs to one person across all their identifiers (phone plus email become one). A group conversation is the union of every `style=43` chat that shares an identical participant roster. `chatIDs` (the chat ROWIDs to extract), `targetHandles` (the counterparty's handle ROWIDs), `identifiers` (normalized phone/email strings), `isGroup`, `participants` (the roster), and `groupName` are its load-bearing fields. It is a value type with no `Data` blobs, so it is `Sendable`.

**Participant** (`Conversation.swift`). One member of a group roster. Carries the handle ROWID (`handleID`), the normalized identifier (phone/email), and a resolvable speaker `label` (filled later from a Contacts map).

**Conversations** (`Conversation.swift`). The enum-of-statics entry point that turns a `ChatDatabase` into `[Conversation]`. `list(from:)` wires it to a database; `group` and `groupGroups` are the pure (no-DB, no-Contacts) folding functions that the unit tests exercise directly.

**GroupStitch** (`Conversation.swift`). How group chats merge: `.exact` (the default and only shipped-by-default behavior) merges only when the sorted participant-handle set is identical; `.fuzzy` is an opt-in heuristic second pass that merges rosters that look like the same group with changed membership. The fuzzy pass merges only maximal cliques (every pair in a cluster must independently match) to block weak transitive chaining, with thresholds gathered in one `FuzzyRule` struct.

**MessageRecord** (`Extractor.swift`). One emitted message: `guid`, `date`, `speaker` label, `isTarget`, `service`, decoded `text`, `hadAttachment`, and netted `reactions`. The public memberwise initializer lets callers build synthetic records to render fixtures without a database. Reactions and system events are not `MessageRecord`s; they are filtered out or carried separately.

**Extractor** (`Extractor.swift`). Turns chat rows into ordered `MessageRecord`s. SQLite merge-sorts the union of `chatIDs` by date in one pass; messages reachable from more than one chat are de-duped by ROWID. It nets reactions, splices attachment placeholders into decoded text, and resolves the speaker label ("Me", "Them", or a per-speaker name in a group). `forConversation(_:globalLabels:)` is the single seam that branches 1:1 vs group labeling.

**Transcript** (`Transcript.swift`). The renderer. `compactText` produces the daily-grouped `.txt` (preamble, day sections, `HH:mm Speaker: body` lines, reaction suffixes); `jsonLines` produces the `.jsonl`. Both are redaction-aware and anonymization-aware and share one body-splice path so the two outputs can never diverge.

**Export** (`Export.swift`). The one pipeline seam: open, preflight, list, then extract, detect, and render one conversation. Before this existed, the app and the CLI each reassembled the extract-detect-render sequence by hand and drifted (the CLI shipped transcripts with no redaction). `Export.render` is the single place that ordering lives.

**ChatDatabase** (`Database.swift`). Read-only access to the copied `chat.db` via a GRDB `DatabaseQueue`. Owns the temp copy, exposes the row-level summary queries (`conversationSummaries`, `groupConversationSummaries`, `handleLabels`), and the schema guard.

**ConversationSummary / GroupConversationSummary** (`Database.swift`). The raw per-chat rows that `Conversations` folds into `Conversation`s. Counts and dates use real messages only (`item_type = 0`, no reactions, no system events).

**Schema guard / required-schema contract** (`Database.swift`). `ChatDatabase.requiredSchema` declares the exact tables and columns the SQL reads. `schemaProblems()` introspects via `PRAGMA table_info` and lists anything missing; `preflight()` throws `UnsupportedSchemaError` when the list is non-empty. The guard fails closed so an unsupported `chat.db` produces a visible error rather than a silently-wrong export.

**Reaction** (`Reactions.swift`). A tapback, after netting adds against removes per (target message, reactor). `Reactions.net` keeps the latest add unless a later remove cleared it.

**Attachment placeholder** (`Attachments.swift`). `AttachmentInfo.placeholder` maps a MIME type / UTI / transfer name to a typed token: `[photo]`, `[video]`, `[gif]`, `[audio]`, `[pdf]`, `[contact]`, `[attachment]`, plus the `[shared location]` fallback. Rich-link previews are dropped (the URL is already in the text).

**ContactsMap** (`Contacts.swift`). Builds a normalized-handle to display-name map (and optional avatar thumbnails) by enumerating Contacts once. `normalizeHandle` lowercases emails and best-effort E.164-normalizes phone numbers so both sides match. Contacts access is optional: a denial degrades to bare identifiers.

**AttributedBody** (`AttributedBody.swift`). Decodes the `attributedBody` typedstream blob (via the Madrid `TypedStream` dependency) to the plain backing string of its `NSAttributedString`. Used because many message bodies live only in this blob, not the `text` column.

**Redaction / RedactionSet** (`Redaction.swift`). A `Redaction` anchors to one message by `guid`, with a half-open UTF-16 range into that message's `text` (a `nil` range means redact the whole message). `RedactionSet` is the per-conversation, value-typed, `Sendable` set; a whole-message redaction supersedes (absorbs) every span redaction for the same guid.

**RedactionMap / OffsetMap** (`RedactionMap.swift`). The forward/inverse coordinate map for one message body: source `text` UTF-16 index to output-body UTF-16 index and back. It models the redaction span collapse and the newline-to-newline-plus-8-spaces indentation as one breakpoint table, so the app can map an output selection back to a source range for click-to-undo.

**SecretCategory and SecretDetector** (`Redaction.swift`, `SecretDetector.swift`). Detectors flag high-harm secrets for review; they never auto-remove. Categories: `password` (in context), `ssn`, `creditCard` (Luhn-gated), `seedPhrase` (BIP-39 checksum), `apiKey` (curated prefixed token formats and PEM headers), `standingCode` (door/gate/PIN keyword proximity), `bankAccount` (IBAN mod-97 and US ABA routing). The design floor is hard: ordinary PII (bare phones, emails, names, street addresses) is never flagged, so a real secret is not buried in alert fatigue.

**ScrubberCategory and SecretScrubber** (`Redaction.swift`, `SecretScrubber.swift`). Scrubbers bulk auto-remove a category when its toggle is on, producing ordinary `Redaction` spans through the same reversible pipeline as a manual redaction (no review alert, the toggle is the consent). Categories: `phone`, `postalAddress` (Apple `NSDataDetector`), `email` (a standard address regex), `otp` (high-precision 2FA forms only). All scrubbers are off by default.

**DetectedSecret** (`Redaction.swift`). One found secret: `guid`, a UTF-16 `range`, and a `SecretCategory`. Drives the amber highlight on still-visible secrets.

**Anonymization map (P1/P2 aliases)** (`Transcript.swift`). `anonymizationMap` builds a stable speaker-to-`PN` map. The account owner ("Me") anchors to P1; every other distinct speaker is numbered by first appearance. Under `anonymize`, speaker prefixes, reaction authors, and whole-word in-body mentions of a known participant name all rewrite to the alias, and the counterparty's number/name is scrubbed from the header. The map is never written into the output, so a reader cannot tell which Person is the user.

**BIP39** (`BIP39Wordlist.swift`). The 2048-word BIP-39 English wordlist in canonical order. Array index is the 11-bit value, so the order is load-bearing for the seed-phrase checksum. Sourced from the MIT-licensed `bitcoin/bips` reference list.

## Module map

| File | Responsibility | Key public types / entry points |
| --- | --- | --- |
| `Conversation.swift` | Fold raw chat rows into people-level conversations (1:1 union, group exact-set stitch, opt-in fuzzy membership-change merge, group speaker labeling) | `Conversation`, `Participant`, `GroupStitch`, `Conversations.list`, `Conversations.group`, `Conversations.groupGroups`, `Conversations.groupSpeakerLabels` |
| `Database.swift` | Read-only copied-DB access, row-level summary queries, the schema guard | `ChatDatabase`, `ChatDatabase.requiredSchema`, `schemaProblems`, `preflight`, `SchemaProblem`, `UnsupportedSchemaError`, `ConversationSummary`, `GroupConversationSummary` |
| `Extractor.swift` | Rows to ordered `MessageRecord`s; speaker labels; attachment splicing; opt-in group system events | `MessageRecord`, `Extractor`, `Extractor.forConversation`, `extractConversation`, `extractSystemEvents` |
| `Transcript.swift` | Render `.txt` and `.jsonl`; redaction splice; anonymization; render marks for the app | `Transcript.compactText`, `Transcript.jsonLines`, `Transcript.redactedText`, `Transcript.renderedBody`, `RenderResult`, `RenderSpan`, `RedactedMark`, `HighlightMark`, `TrimOptions`, `GroupRenderInfo`, `SystemEvent` |
| `Export.swift` | The single extract-detect-render pipeline seam, plus prepared-record helpers for alternate output formats | `Export`, `Export.render`, `Export.Scope`, `Export.Format`, `Export.Rendered`, `records`, `preparedRecords`, `effectiveRedactions`, `preparedRedactedRecords` |
| `Redaction.swift` | Redaction value types and the category enums | `Redaction`, `RedactionSet`, `SecretCategory`, `ScrubberCategory`, `DetectedSecret` |
| `RedactionMap.swift` | Source-to-output UTF-16 offset map for one message body | `OffsetMap` (internal) |
| `SecretDetector.swift` | On-device detection of high-harm secrets (flag for review) | `SecretDetector.detect` |
| `SecretScrubber.swift` | On-device opt-in auto-remove of ubiquitous PII | `SecretScrubber.scrub` |
| `Contacts.swift` | Build the normalized-handle to name/avatar map; handle normalization | `ContactsMap`, `buildContactInfo`, `normalizeHandle`, `normalizePhone`, `resolve` |
| `Attachments.swift` | Typed attachment placeholder mapping | `AttachmentInfo`, `AttachmentInfo.placeholder` |
| `AttributedBody.swift` | Decode the typedstream `attributedBody` blob to plain text | `AttributedBody.decode` |
| `Reactions.swift` | Reaction value type, tapback mapping, add/remove netting | `Reaction`, `Reactions` (internal) |
| `BIP39Wordlist.swift` | The canonical BIP-39 wordlist for the seed-phrase checksum | `BIP39.words`, `BIP39.wordSet`, `BIP39.indexOf` (internal) |
| `Sources/lembic-cli/LembicCLI.swift` | Command-line front end over the engine | `LembicCLI`, `Export` and `ConversationsCommand` subcommands |

## Key invariants and contracts

### The golden-oracle contract

`Transcript.compactText` and `jsonLines` output is byte-anchored to committed golden fixtures in `Tests/LembicKitTests/Fixtures/`: `golden_basic.txt`, `golden_redacted.txt`, `golden_redacted.jsonl`, `golden_anonymized.txt`, `golden_name_alias.txt`, `golden_group.txt`, `golden_group_events.txt`. The tests compare with exact `==`.

The renderer formats dates in `.current` (local time) in production, but the golden tests inject a fixed `TimeZone` (`Fixtures.goldenTimeZone`, `America/Chicago`) so the committed bytes are deterministic on any machine. `Fixtures/.gitattributes` (`* -text`) keeps git from normalizing line endings, which would silently break the bytes.

When the output legitimately changes, regenerate rather than hand-edit:

```sh
LEMBIC_REGOLD=1 swift test --filter golden   # rewrites Fixtures/golden_* from the current renderer
git diff Tests/LembicKitTests/Fixtures        # review, confirm the change is intended, then commit
```

The regold writer targets the source `Fixtures/` directory via `#filePath`, not the `.build` bundle copy.

### The schema-sanity guard

`ChatDatabase.requiredSchema` is the contract: the exact tables and columns the engine's SQL reads, declared as `(table, columns)` pairs. It must stay in lockstep with the queries in `Extractor` and `Database`. A column added to a query must be added here. `ROWID` is intentionally absent: SQLite exposes it on every non-`WITHOUT ROWID` table regardless of declaration, so checking it would false-fail.

`schemaProblems()` returns every missing table or column. `preflight()` throws `UnsupportedSchemaError` when any are missing, failing closed. Unknown `chat.style` values and an empty store are valid (a fresh install has no chats yet) and are not reported here.

Three columns the opt-in group system-event stream reads (`group_action_type`, `group_title`, `other_handle`) are deliberately not in `requiredSchema` (the default export never touches them). `hasColumns(_:inTable:)` probes for them at runtime so a missing column degrades the toggle to an empty stream rather than throwing at statement-prepare time.

### Copy-then-read

`ChatDatabase(copying:)` copies `chat.db` and its `-wal`/`-shm` sidecars to a private temp directory and opens the copy read-only, so the engine never holds even a read lock on the live Messages store. Connection lifecycle: `cleanUp()` drops the SQLite connection before deleting the temp files (removing them while GRDB holds them open trips SQLite's "vnode unlinked while in use" guard). `cleanUp()` is idempotent and also runs from `deinit`. `ChatDatabase` is `@unchecked Sendable` so a caller can copy the DB once and reuse the instance across the conversation list and every render (the underlying `DatabaseQueue` is thread-safe for concurrent reads). `Export` owns this handle for the same reason.

### Detectors flag, scrubbers remove

This honesty rule is stated in the code and enforced by tests. A `SecretDetector` only produces `DetectedSecret`s (a flag-for-review list with a highlight); it never auto-removes. A `SecretScrubber` only removes a category that is explicitly enabled, and only by producing reversible `Redaction` spans. Both default to safe: scrubbers default to the empty set (off), and the detector's phone/email/name/address floor is asserted by the test suite. The two surfaces are deliberately split so ubiquitous PII auto-removal can never bury a real high-harm secret in alert noise.

### Byte-identical defaults

Many features (group rendering, system events, trim, anonymize, scrubbers, fuzzy stitch) are written so the default path reproduces the prior bytes exactly. The golden tests are the proof.

## Build, test, run

This is a Swift Package. From the repository root:

```sh
swift build                    # build the library and lembic-cli
swift test                     # run the engine suite
swift test --filter golden     # just the byte-anchored golden tests
```

`lembic-cli` takes a `chat.db` path and raw ROWIDs. There is intentionally no contact picker in the CLI: it takes `--chat-id` and `--target-handles` (comma-separated handle ROWIDs) directly. That manual friction is by design (the GUI handles discovery). To discover the ROWIDs, use the `conversations` subcommand first:

```sh
# list people, newest first, with the chat-id and target-handles each export needs
swift run lembic-cli conversations /path/to/chat.db

# export one thread to messages_<number>.txt and .jsonl
swift run lembic-cli export /path/to/chat.db --chat-id 32 --target-handles 3,73,1248 --number +15551234567 --out-dir .
```

Relevant flags: `--union` (merge all of a person's 1:1 chats into one export, with a reconciliation printout), `--redact-detected` (build redactions from the auto-detected secrets and apply them to both outputs), `--anonymize` (P1/P2 aliasing), `--contacts` (resolve handles to names, which triggers a Contacts/TCC prompt), `--sample N` (print the first N rendered messages instead of writing files). `export` is the default subcommand, so `lembic-cli <db>` still exports.

Note: the executable embeds an `Info.plist` via linker flags (`Sources/lembic-cli/Info.plist`), because TCC auto-denies privacy requests from a binary that has no usage description.

Fixtures: tests build in-memory SQLite databases from the schema strings in `Tests/LembicKitTests/Support/Fixtures.swift` via `makeInMemoryDB` / `openChatDB`. A demo path lets `ContactsMap` read names from a vCard (`Tests/LembicKitTests/Fixtures/contacts.vcf`, or any file pointed to by the `LEMBIC_CONTACTS` environment variable) instead of the system store, so a fixture gets real names without a TCC prompt.

## Extension points

**Add a new detector.** Add a case to `SecretCategory` in `Redaction.swift`, add a private `detectX` function and its `static let` regex(es) in `SecretDetector.swift`, and call it inside `SecretDetector.detect` under an `enabled.contains(.x)` guard. Keep the alert-fatigue floor: do not add ubiquitous-PII detection here. Anything self-validating (a checksum) needs no context keyword; anything common (like the routing number) should require a nearby keyword. Add tests to `SecretDetectorTests.swift` including a false-positive guard.

**Add a new scrubber category.** Add a case to `ScrubberCategory` in `Redaction.swift`, add the matcher in `SecretScrubber.swift` (an `NSDataDetector` type or a regex), and call it inside `SecretScrubber.scrub` under a `categories.contains(.x)` guard. It must default off (the toggle is the consent) and emit `Redaction` spans over the leaking value only. Add tests to `SecretScrubberTests.swift`, including the default-off proof.

**Add a new output format.** Add a case to `Export.Format` in `Export.swift` and render it inside `Export.render(records:...)` from the same scoped, detected, redaction-folded inputs the existing formats use. For a format that consumes `MessageRecord`s directly (rather than a rendered string), use `preparedRedactedRecords(_:scope:redactions:)`, which bakes trim, anonymization, and effective redactions into each record via the engine's own logic so the new format cannot drift from the `.txt`/`.jsonl` outputs or leak a scrubbed value. Expect to regenerate goldens if the new format gets a golden fixture.

**Tune fuzzy group stitching.** The thresholds for the opt-in membership-change merge are all in the `FuzzyRule` struct in `Conversation.swift` (`minSubsetRatio`, `maxRosterDelta`, `minJaccard`, `minRosterSize`). The pairwise predicate `fuzzyPairMatches` is pure and unit-testable on synthetic conversations.
