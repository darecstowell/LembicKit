# LembicKit

LembicKit reads a macOS Messages `chat.db` (SQLite), folds its rows into people-level conversations, and renders LLM-ready transcripts: a compact daily-grouped `.txt` and one JSON object per message (`.jsonl`). It also runs on-device detection of high-harm secrets and reversible redaction over the same message bodies. The package ships a library target (`LembicKit`) and a command-line tool (`lembic-cli`). It targets macOS 14 (Sonoma) and never touches the live Messages store: it opens `chat.db` read-only in place, reads the live WAL, and copies nothing.

## Domain glossary

These are the core nouns, drawn from the actual type names.

**Conversation** (`Conversation.swift`). One person or one group, after row-level chats are folded together. A 1:1 conversation is the union of every `style=45` chat that belongs to one person across all their identifiers (phone plus email become one). A group conversation is the union of every `style=43` chat that holds the same people (a person's email, phone, SMS, and RCS handles count as one) with names that do not conflict, plus chats Apple links through `chat.group_id` or `chat_lookup`. `id` (stable: `chat:` plus the smallest `chat.guid` in the union, so renames, Contacts changes, and member changes do not move it), `legacyIDs` (the 0.3.1 keys, for migrating saved data), `chatGUIDs`, `chatIDs` (the chat ROWIDs to extract), `targetHandles` (the counterparty's handle ROWIDs), `identifiers` (normalized phone/email strings), `isGroup`, `participants` (the roster), and `groupName` are its load-bearing fields. It is a value type with no `Data` blobs, so it is `Sendable`.

**Participant** (`Conversation.swift`). One person in a group roster. Carries their main handle ROWID (`handleID`), every handle of theirs in the group (`handleIDs`), the normalized identifier (phone/email), and a resolvable speaker `label` (filled later from a Contacts map). The extractor gives every handle in `handleIDs` the same label.

**Conversations** (`Conversation.swift`). The enum-of-statics entry point that turns a `ChatDatabase` into `[Conversation]`. `list(from:)` wires it to a database; `group` and `groupGroups` are the pure (no-DB, no-Contacts) folding functions that the unit tests exercise directly.

**GroupStitch** (`Conversation.swift`). How group chats merge: `.exact` (the default) merges chats with the same people (by person key, see `Conversations.personKeys`) whose names agree, plus chats Apple links; `.fuzzy` is an opt-in heuristic second pass that merges rosters that look like the same group with changed membership. Two rules hold in both passes: chats with different non-empty names never merge, and when one roster carries two names its unnamed chats stay apart. The fuzzy pass also never merges two groups that were active at the same time. It merges only maximal cliques (every pair in a cluster must independently match) to block weak transitive chaining, with thresholds gathered in one `FuzzyRule` struct.

**Roster** (`Conversation.swift`). A group's `participants`: the people in `chat_handle_join`, plus former members (people who wrote, or whom an add or remove event names, but who are no longer listed; `Participant.isFormer`, shown as "(left)"). The owner's own handles (from `destination_caller_id` on the owner's messages and from the Me card) are never participants; they are `Conversation.ownerHandles` and label as "Me". The fuzzy pass compares current members only. An address is the owner's only when the Me card has it or the owner sent from it (`destination_caller_id`) in two or more chats; a 1:1 whose identifiers are all the owner's is a note to self (`Conversation.isNoteToSelf`), where every row is "Me" and incoming echoes of sent notes are dropped.

**Person key** (`Conversation.swift`). `Conversations.personKeys` joins handle ROWIDs that share a normalized identifier, a `handle.person_centric_id`, or a Contacts card (`ContactsMap.ContactInfo.contactIDs`). A contact name alone never joins two handles.

**MessageRecord** (`Extractor.swift`). One emitted message: `guid`, `date`, `speaker` label, `isTarget`, `service`, decoded `text`, `hadAttachment`, netted `reactions`, and `flags`. The public memberwise initializer lets callers build synthetic records to render fixtures without a database. Reactions and system events are not `MessageRecord`s; they are filtered out or carried separately.

**Fail-safe body** (`Extractor.swift`, `AttributedBody.swift`). A row is never shown as a normal message unless the engine read it cleanly. A body that does not decode is salvaged (the string up to the first missing or invalid byte) or taken from `text`, and ends with `[message may be incomplete]`; with nothing to read it is `[message could not be read]`. An unknown `item_type` with text ends with `[unknown message type]`. `MessageRecord.flags` carries the same facts. A row that is not shown at all (no body, an unknown type with no text, an unknown reaction type) is a `SkippedMessage`: `Extractor.extract` returns them, and `Export.Rendered.skipped` lists the ones in scope. A U+FFFC with no attachment row renders `[attachment]`.

**Extractor** (`Extractor.swift`). Turns chat rows into ordered `MessageRecord`s. SQLite merge-sorts the union of `chatIDs` by date in one pass; messages reachable from more than one chat are de-duped by ROWID. It nets reactions, splices attachment placeholders into decoded text, and resolves the speaker label ("Me", "Them", or a per-speaker name in a group). `forConversation(_:globalLabels:)` is the single seam that branches 1:1 vs group labeling.

**Transcript** (`Transcript.swift`). The renderer. `compactText` produces the daily-grouped `.txt` (preamble, day sections, `HH:mm Speaker: body` lines, reaction suffixes); `jsonLines` produces the `.jsonl`. Both are redaction-aware and anonymization-aware and share one body-splice path (`BodySplice`) so the two outputs can never diverge.

**Export** (`Export.swift`). The one pipeline seam: open, preflight, list, then extract, detect, and render one conversation. Before this existed, the app and the CLI each reassembled the extract-detect-render sequence by hand and drifted (the CLI shipped transcripts with no redaction). `Export.render` is the single place that ordering lives.

**Scope renderer** (`ScopeRenderer.swift`). `Export.ScopeRenderer` holds one extracted conversation so a caller can re-render it as the scope changes (a date slider). `render(formats:scope:redactions:detect:)` returns exactly what `Export.render(records:...)` returns; it finds the detector and scrubber hits over the whole thread once per category set and reuses them. A detector piece (one message, a join, an answer, a key block) is reused for a scope only when it read nothing outside the scope; the pieces at the scope edges run again inside it. Both paths run through one internal render core and one piece assembly (`DetectorInput`), and the parity tests compare every field byte for byte. `Transcript.RenderResult.empty` is the result of an empty scope.

**ChatDatabase** (`Database.swift`). Read-only, in-place access to `chat.db` via a GRDB `DatabaseQueue`. Exposes the row-level summary queries (`conversationSummaries`, `groupConversationSummaries`, `handleLabels`), and the schema guard.

**ConversationSummary / GroupConversationSummary** (`Database.swift`). The raw per-chat rows that `Conversations` folds into `Conversation`s. Counts and dates use real messages only (`item_type = 0`, no reactions, no system events).

**Schema guard / required-schema contract** (`Database.swift`). `ChatDatabase.requiredSchema` (plus `requiredBodyColumns`: `text` or `attributedBody`) declares the core columns the engine cannot work without. `ChatDatabase.optionalSchema` declares every other column the SQL reads. `schemaProblems()` introspects via `PRAGMA table_info` and lists missing core columns; `preflight()` throws `UnsupportedSchemaError` when that list is non-empty. A missing optional column never fails: each read session probes once into a `SchemaSnapshot` and selects `NULL` in its place, so one feature degrades (for example, emoji tapbacks fall back to "•" on macOS 14). `missingOptionalColumns()` lists those gaps for diagnostics.

**Reaction** (`Reactions.swift`). A tapback, sticker, or poll vote, after netting adds against removes per (target message, reactor, kind). `Reactions.kind(of:)` classifies `associated_message_type`: 0, 2, and 3 are messages; 1000 is a sticker placed on a bubble; 2000 to 2999 add a tapback (the classic set, "sticker" for 2007, else the row's emoji, else "•"); 3000 to 3999 remove one; 4000 is a poll vote. Any other type is never shown as a message. `Reactions.net` keeps the latest add unless a later remove cleared it; sticker tapbacks net apart from emoji tapbacks.

**Attachment placeholder** (`Attachments.swift`). `AttachmentInfo.placeholder` maps a MIME type / UTI / transfer name to a typed token: `[photo]`, `[video]`, `[gif]`, `[audio]`, `[pdf]`, `[contact]`, `[location]`, `[sticker]`, `[genmoji: description]`, `[attachment]`, plus the `[shared location]` fallback. A voice note with a transcription renders `[audio: "words"]`. Rich-link previews are dropped (the URL is already in the text).

**App message** (`AppMessage.swift`). A message whose `balloon_bundle_id` names an app (Apple Pay, Polls, Check In, handwriting, Digital Touch, Find My, or a third-party app). Its body is a lone U+FFFC, so the extractor renders one token from `payload_data` instead, for example `[Apple Pay: Sent $20 with Apple Pay.]`, `[poll: Lunch? (Thai / Tacos)]`, or `[app: GamePigeon (Dots & Boxes)]`; an app it cannot read becomes `[app message]`. A poll vote (`associated_message_type` 4000) attaches to its poll like a reaction (`[Them: voted Tacos]`). Link previews (`URLBalloonProvider`) are not app messages.

**ContactsMap** (`Contacts.swift`). Builds a normalized-handle to display-name map (and optional avatar thumbnails) by enumerating Contacts once. `normalizeHandle` lowercases emails and best-effort E.164-normalizes phone numbers so both sides match: it strips international exit codes (`00`, `011`, `0011`, `010`), drops the national trunk prefix, and adds the calling code of the region. The pipeline entry points (`buildContactInfo`, `resolve`, `Conversations.list`) default to `ContactsMap.currentRegion()` (the Contacts setting, else the system region); the pure helpers default to US. A chat.db number that matches no card exactly can still match a card saved in national form under the wrong country code (same last nine digits, a different calling code, exactly one card). Contacts access is optional: a denial degrades to bare identifiers.

**AttributedBody** (`AttributedBody.swift`). Decodes the `attributedBody` typedstream blob (via the Madrid `TypedStream` dependency) to the plain backing string of its `NSAttributedString`. Used because many message bodies live only in this blob, not the `text` column.

**Redaction / RedactionSet** (`Redaction.swift`). A `Redaction` anchors to one message by `guid`, with a half-open UTF-16 range into that message's `text` (a `nil` range means redact the whole message). `RedactionSet` is the per-conversation, value-typed, `Sendable` set; a whole-message redaction supersedes (absorbs) every span redaction for the same guid. A span past the end of its message (a stale anchor) hides the whole message, so a changed text never fails open. `RedactionAnchor` adds an HMAC fingerprint of the covered text, so a caller that saves redactions can move them when the text shifts.

**BodySplice / OffsetMap** (`BodySplice.swift`). The one splice path for a message body. `BodySplice` builds the substitutions (redaction spans as `[redacted]`, the placeholder strip, name aliases; redactions win) and applies them; `Transcript`, `IdentityScrub`, and the public body helpers all use it. `OffsetMap` is the forward/inverse coordinate map for one body: source `text` UTF-16 index to output-body UTF-16 index and back. It models the substitutions and the newline-to-newline-plus-8-spaces indentation as one breakpoint table, so the app can map an output selection back to a source range for click-to-undo. `NormalizedText` maps a detection hit in normalized text back to source offsets.

**SecretCategory and SecretDetector** (`Redaction.swift`, `SecretDetector.swift`). Detectors flag high-harm secrets for review; they never auto-remove. Categories: `password` (in context), `ssn`, `creditCard` (Luhn and issuer checks), `seedPhrase` (BIP-39 checksum), `apiKey` (vendor token formats, named secrets, private key blocks), `standingCode` (door/gate/PIN keyword proximity), `bankAccount` (IBAN mod-97, US ABA routing, account numbers after a keyword), `idNumber` (passport, license, national and health IDs), `recoveryKey` (recovery keys, backup codes, TOTP secrets), `invisibleInk` (a message sent with that effect, flagged whole). Each body is first normalized (`TextNormalizer`); every flag maps back to the source text and covers the whole value. Rules also see the message before (a keyword asked there counts), messages split over 2 to 4 sends are joined, and an answer to "what's the wifi password" is checked. Each rule sits behind a cheap gate (`TextProfile`); a test proves the gated output equals a full run. A hit in a string that is not a message body (group name, event line, label) reads `[redacted]`. The design floor is hard: ordinary PII (bare phones, emails, names, street addresses) is never flagged, so a real secret is not buried in alert fatigue.

**ScrubberCategory and SecretScrubber** (`Redaction.swift`, `SecretScrubber.swift`). Scrubbers bulk auto-remove a category when its toggle is on, producing ordinary `Redaction` spans through the same reversible pipeline as a manual redaction (no review alert, the toggle is the consent). Categories: `phone`, `postalAddress` (Apple `NSDataDetector`), `email` (a standard address regex), `otp` (a code next to a sign-in cue, the code-first and domain-bound forms, `G-123456`; never "zip code" or a bare number). Scrubbers run on normalized text behind gates; the address gate is a heuristic. All scrubbers are off by default.

**DetectedSecret** (`Redaction.swift`). One found secret: `guid`, a UTF-16 `range`, and a `SecretCategory`. Drives the amber highlight on still-visible secrets.

**Anonymization map (P1/P2 aliases)** (`Transcript.swift`). `anonymizationMap` builds a stable speaker-to-`PN` map. The account owner ("Me") anchors to P1; every other distinct speaker is numbered by first appearance. Under `anonymize`, speaker prefixes, reaction authors, and in-body mentions of a known name all rewrite to the alias, and the counterparty's number/name is scrubbed from the header. Known names are the speaker labels plus `Export.Scope.knownNames` (label to full names, such as the contact name for "Them" and the owner's name for "Me"); every part of a name matches too (`NameMatcher`). A part shared by two people reads `[name]`, and a name that is also a common word ("Will") matches only as written. The map is never written into the output, so a reader cannot tell which Person is the user.

**BIP39** (`BIP39Wordlist.swift`). The 2048-word BIP-39 English wordlist in canonical order. Array index is the 11-bit value, so the order is load-bearing for the seed-phrase checksum. Sourced from the MIT-licensed `bitcoin/bips` reference list.

## Module map

| File | Responsibility | Key public types / entry points |
| --- | --- | --- |
| `Conversation.swift` | Fold raw chat rows into people-level conversations (1:1 union, group exact-set stitch, opt-in fuzzy membership-change merge, group speaker labeling) | `Conversation`, `Participant`, `GroupStitch`, `Conversations.list`, `Conversations.group`, `Conversations.groupGroups`, `Conversations.groupSpeakerLabels` |
| `Database.swift` | Read-only copied-DB access, row-level summary queries, the schema guard | `ChatDatabase`, `ChatDatabase.requiredSchema`, `schemaProblems`, `preflight`, `SchemaProblem`, `UnsupportedSchemaError`, `ConversationSummary`, `GroupConversationSummary` |
| `Extractor.swift` | Rows to ordered `MessageRecord`s; speaker labels; attachment splicing; opt-in group system events | `MessageRecord`, `Extractor`, `Extractor.forConversation`, `extractConversation`, `extractSystemEvents` |
| `Transcript.swift` (+ `Transcript+Text.swift`, `Transcript+JSON.swift`, `Transcript+Body.swift`, `Transcript+Placeholders.swift`, `LocalClock.swift`) | Render `.txt` (`+Text`) and `.jsonl` (`+JSON`); the public body helpers (`+Body`); placeholder strip and legend; local clock and DST hours; anonymization; render marks for the app | `Transcript.compactText`, `Transcript.jsonLines`, `Transcript.redactedText`, `Transcript.renderedBody`, `RenderResult`, `RenderSpan`, `RedactedMark`, `HighlightMark`, `TrimOptions`, `GroupRenderInfo`, `SystemEvent` |
| `Export.swift` | The single extract-detect-render pipeline seam, plus prepared-record helpers for alternate output formats | `Export`, `Export.render`, `Export.Scope`, `Export.Format`, `Export.Rendered`, `unredactedRecords`, `unredactedPreparedRecords`, `effectiveRedactions`, `preparedRedactedRecords` (both prepared-record APIs share one internal `prepare` step) |
| `ScopeRenderer.swift` | Fast re-renders of one extracted conversation over many scopes, with memoized detector and scrubber hits | `Export.ScopeRenderer` |
| `Redaction.swift` | Redaction value types and the category enums | `Redaction`, `RedactionSet`, `SecretCategory`, `ScrubberCategory`, `DetectedSecret` |
| `QuoteReactions.swift` | Moves a quoted message's redactions onto an SMS/RCS tapback that quotes it (`Loved “…”`) | `QuoteReactions` (internal, called from `Export.effectiveRedactions`) |
| `RedactionAnchor.swift` | Saved redactions with a keyed fingerprint of the covered text, so a changed message moves the anchor or hides the whole message | `RedactionAnchor`, `RedactionSet.anchors(in:key:)`, `RedactionSet.resolve(_:records:key:)` |
| `BodySplice.swift` | The one body-splice path, the source-to-output UTF-16 offset map, and the normalized-to-source map | `BodySplice`, `OffsetMap`, `NormalizedText` (internal) |
| `SecretDetector.swift` | On-device detection of high-harm secrets (flag for review): the entry point, flag merging, key blocks, seed phrases, and checksums (the per-record pieces are in `DetectorInput.swift`) | `SecretDetector.detect` |
| `DetectorInput.swift` | The detector's per-record inputs and its four pieces, each run inside explicit bounds, and the one assembly that orders the flags | `DetectorInput` (internal) |
| `DetectorRules.swift` | The per-message scan and its ordered rule table (category, gate, rule) | `DetectorScan`, `DetectorScan.rules` (internal) |
| `Detectors/*.swift` | One file per category group (`Cards`, `Bank`, `GovernmentIDs`, `Passwords`, `APIKeys`, `RecoveryAndSeeds`, `Codes`): the regexes, keywords, and rule for each, as `DetectorScan` extensions | `DetectorScan` (internal) |
| `Detectors/Checksums.swift` | Pure validators: Luhn, issuer table, SSN shape, mod-97, ABA, TFN, CPF, NIR, NHS, Verhoeff, codice fiscale | `DetectorScan.luhn` and others (internal) |
| `Detectors/TextProfile.swift` | One pass over a body for the counts the gates use | `TextProfile` (internal) |
| `TextNormalizer.swift` | A detection copy of a body with odd characters undone | `TextNormalizer` (internal) |
| `SecretScrubber.swift` | On-device opt-in auto-remove of ubiquitous PII | `SecretScrubber.scrub` |
| `NameMatcher.swift` | Finds known names and name parts in message text for anonymize | `NameMatcher` (internal), `Export.knownNames(for:labels:adding:)` |
| `IdentityScrub.swift` | Carries enabled scrubbers to the header identifier, group name, roster, speaker labels, reaction authors, and event lines (an identifier label becomes `Member N`) | `IdentityScrub` (internal) |
| `Contacts.swift` | Build the normalized-handle to name/avatar map; handle normalization | `ContactsMap`, `buildContactInfo`, `normalizeHandle`, `normalizePhone`, `resolve` |
| `AppMessage.swift` | App-message tokens from `payload_data`, poll options and votes | `AppMessage` (internal) |
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

Two lists are the contract, declared as `(table, columns)` pairs. `ChatDatabase.requiredSchema` (and `requiredBodyColumns`) holds only the core columns the engine cannot work without; a missing one fails closed. `ChatDatabase.optionalSchema` holds every other column the SQL reads. Both must stay in lockstep with the queries in `Extractor` and `Database`: a column added to a query goes in one of the two lists, and an optional column must be selected through `SchemaSnapshot.column(_:_:_:)`, which yields `NULL` when the column is absent. A feature that needs several optional columns together (system events, attachment links, person links, chat links) declares the set next to `optionalSchema` and checks it with `SchemaSnapshot.has(_:)`. `Conversations.list` loads one snapshot and passes it to every query it runs. `ROWID` is intentionally absent: SQLite exposes it on every non-`WITHOUT ROWID` table regardless of declaration, so checking it would false-fail.

`schemaProblems()` returns every missing core table or column. `preflight()` throws `UnsupportedSchemaError` when any are missing. Unknown `chat.style` values and an empty store are valid (a fresh install has no chats yet) and are not reported here. `missingOptionalColumns()` lists the optional gaps; they never block an export.

### Read in place

`ChatDatabase(at:)` opens `chat.db` read-only, in place, and reads the live WAL; nothing is copied and nothing is written. `cleanUp()` drops the connection; it is idempotent and also runs from `deinit`. `ChatDatabase` is `@unchecked Sendable` so a caller can open the DB once and reuse the instance across the conversation list and every render (the underlying `DatabaseQueue` is thread-safe for concurrent reads). `Export` owns this handle for the same reason. To refresh an open thread, poll `changeToken()`: it moves on any commit (`PRAGMA data_version` on this connection plus `MAX(ROWID)`), so edits, unsends, and deletions are seen, not only new rows.

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

Fixtures: tests build in-memory SQLite databases from the schema strings in `Tests/LembicKitTests/Support/Fixtures.swift` via `makeInMemoryDB` / `openChatDB`. A demo path lets `ContactsMap` read names from a vCard (`Tests/LembicKitTests/Fixtures/contacts.vcf`, or any file pointed to by the `LEMBIC_CONTACTS` environment variable) instead of the system store, so a fixture gets real names without a TCC prompt. `LEMBIC_CONTACTS` works in Debug builds and outside an app bundle (the CLI); a bundled `DemoData/contacts.vcf` is read in Debug builds only, so a Release app always uses the real Contacts store.

## Extension points

**Add a new detector.** Add a case to `SecretCategory` in `Redaction.swift`, add the rule function and its `static let` regex(es) in a `DetectorScan` extension in `Sources/LembicKit/Detectors/` (the file for its category group, or a new one), and put any pure validator in `Detectors/Checksums.swift` with a direct test in `ChecksumTests.swift`. Add one row to `DetectorScan.rules` in `DetectorRules.swift` at the place it should run: the category, a gate that only skips text the rule cannot match, and the rule. Add cases to the tune corpus in `Tests/LembicKitTests/Fixtures/redaction-corpus` (never to a `heldout-` set) and raise the floors in `RedactionCorpusTests`. Keep the alert-fatigue floor: do not add ubiquitous-PII detection here. Anything self-validating (a checksum) needs no context keyword; anything common (like the routing number) should require a nearby keyword. Add tests to `SecretDetectorTests.swift` including a false-positive guard.

**Add a new scrubber category.** Add a case to `ScrubberCategory` in `Redaction.swift`, add the matcher in `SecretScrubber.swift` (an `NSDataDetector` type or a regex), and call it inside `SecretScrubber.scrub` under a `categories.contains(.x)` guard. It must default off (the toggle is the consent) and emit `Redaction` spans over the leaking value only. Add tests to `SecretScrubberTests.swift`, including the default-off proof.

**Add a new output format.** Add a case to `Export.Format` in `Export.swift` and render it inside `Export.render(records:...)` from the same scoped, detected, redaction-folded inputs the existing formats use. For a format that consumes `MessageRecord`s directly (rather than a rendered string), use `preparedRedactedRecords(_:scope:redactions:)`, which bakes trim, anonymization, and effective redactions into each record via the engine's own logic so the new format cannot drift from the `.txt`/`.jsonl` outputs or leak a scrubbed value. Expect to regenerate goldens if the new format gets a golden fixture.

**Tune fuzzy group stitching.** The thresholds for the opt-in membership-change merge are all in the `FuzzyRule` struct in `Conversation.swift` (`minSubsetRatio`, `maxRosterDelta`, `minJaccard`, `minRosterSize`). The pairwise predicate `fuzzyPairMatches` is pure and unit-testable on synthetic conversations.
