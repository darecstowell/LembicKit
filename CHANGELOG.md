# Changelog

All notable changes to LembicKit are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

LembicKit is pre-1.0, so minor versions can still carry breaking API changes.

## [Unreleased]

### Changed

- Transcript headers say "Messages transcript" (and "Messages group
  transcript"), not "iMessage", because SMS and RCS threads export too. The
  attachment legend lists only the placeholder kinds that occur in the
  transcript, and is left out when there are none. JSONL `svc` uses plain
  labels: iMessage is left out, `iMessageLite` reads "iMessage via satellite"
  (lembickit.md F25).
- JSONL `"d"` is ISO 8601 with the UTC offset (`2026-11-01T01:10:00-06:00`),
  not a bare local time, so a DST fall-back hour sorts and reads correctly
  (lembickit.md F24).
- `Conversation.id` is now stable: `chat:` plus the smallest `chat.guid` in the
  conversation. A contact rename, a Contacts grant or revoke, a group rename, or a
  member change no longer moves it, so per-conversation saved data stays attached.
  The 0.3.1 keys (contact name, bare identifier, `group:<handle ROWIDs>`) are in the
  new `Conversation.legacyIDs` for migration, and every chat's GUID is in
  `Conversation.chatGUIDs`. `ConversationSummary` and `GroupConversationSummary`
  carry the new `guid` field (bugs.md #5, redaction.md F10).

### Added

- `ChatDatabase.changeToken()`: moves on any commit (an edit, an unsend, or a
  delete, not only a new row), so a live view can refresh. `messageWatermark()`
  still works but misses changes that add no row (lembickit.md F20).
- `Conversations.personKeys(handleLabels:personCentricIDs:contactIDs:)`,
  `ChatDatabase.personCentricIDs()`, and `ChatDatabase.groupChatLinks()` (reads
  `chat_lookup` on macOS 26 when present).
- `ContactsMap.ContactInfo.contactIDs` (normalized handle to `CNContact.identifier`)
  and a `contactIDs:` parameter on `Conversations.list(from:...)`. Pass it so one
  person's handles join by Contacts card, not by name.
- `Participant.handleIDs`, `Conversation.firstMessageDate`, and
  `GroupConversationSummary.groupID` and `.firstMessageDate`.

### Fixed

- Faster extraction and transcript text, with the same output. On a synthetic
  200k-message thread, `extractConversation` drops from 4.5 s to 1.7 s,
  `compactText` from 1.8 s to 1.15 s, and `jsonLines` from 0.97 s to 0.78 s. The
  group list queries start from `chat` (performance.md #7, #15).
- The transcript names its time zone, and a DST fall-back hour no longer reads
  out of order. The header says `# Times are local (America/Chicago), 24h.`
  (the zone is left out when anonymizing), and a clock time that happens twice
  shows its zone, for example `01:30 CDT` then `01:10 CST` (lembickit.md F24).
- An unsent message leaves a trace, and its text never surfaces. The extractor
  reads the `rp` key of `message_summary_info` as well as `date_retracted`. A
  fully unsent message is one `[unsent a message]` line
  (`MessageRecord.Flags.unsent`). When only some parts were unsent, those parts
  are cut from the body by their part runs and the line ends with
  `[part of this message was unsent]` (`.partlyUnsent`). When the parts cannot
  be found, the whole body is hidden (lembickit.md F23).
- Every line break indents like a newline, and a NUL no longer cuts a message.
  `\r\n`, `\r`, U+2028, U+2029, and U+0085 become `\n`, other C0 controls
  except tab become a space, and the `text` column is read as bytes
  (lembickit.md F22).
- A received row with a NULL, 0, or unknown `handle_id` no longer reads "h0".
  In a 1:1 every row not from the owner is "Them" (reactions too, so they net
  with the counterparty's). In a group such a row is "Unknown sender", and an
  event line about an unknown handle uses the subjectless phrasing
  (lembickit.md F21).
- A note to self shows each note once. A 1:1 whose identifiers all belong to the
  owner is `Conversation.isNoteToSelf`: every row is "Me", the incoming copy of
  each sent note (same text within a minute) is dropped and counted as
  `SkippedMessage.Reason.echo`, and the header reads "notes to self". An address
  counts as the owner's when the Me card has it or the owner sent from it in two
  or more chats (`Conversations.ownerAddresses(seen:)`), so one odd row never
  turns another person into "Me". `Transcript.compactText` and
  `Export.render(records:...)` take a `noteToSelf:` flag (lembickit.md F19).
- Business chats keep their real id. `normalizeHandle` returns a handle with a
  `:` (for example `urn:biz:…`) or a letter unchanged, so it no longer becomes
  a fake phone number like `+186231245980123456789`. The 0.3.1 key stays in
  `Conversation.legacyIDs` for migration (lembickit.md F18).
- Old rows stored in seconds show their real date (2016, not 2000-12-31). One
  helper reads `message.date` as nanoseconds at or above 10^12 and as seconds
  below it, in the extractor, the event stream, the summaries, and
  `messageDateBounds()`, and the extractor sorts on the same normalized value.
  A date of 0, NULL, or below 0 is unknown: the row is skipped and counted as
  `SkippedMessage.Reason.invalidDate` (lembickit.md F17).
- Attachment placeholders sit where they belong. Each U+FFFC pairs with the
  attachment its `__kIMFileTransferGUIDAttributeName` names (`attachment.guid`,
  new `AttachmentInfo.guid`), and falls back to join order only when no GUID
  matches (lembickit.md F16).
- The group roster is complete and correct. A person who wrote in the group or
  was added or removed, but is no longer a member, is listed after the members
  as "Carla (left)" (`Participant.isFormer`, `GroupRenderInfo.formerLabels`) and
  gets the same label in the body and in event lines. The owner's own second
  number or email is never a member: it is found from `destination_caller_id`
  on the owner's messages (`ConversationSummary.ownerIdentifiers`,
  `GroupConversationSummary.ownerIdentifiers`) and from the Me card
  (`ContactInfo.ownerIdentifiers`), and its messages label as "Me"
  (`Conversation.ownerHandles`). `groupParticipantMessageCounts()` now also
  returns people that add or remove events name, with a count of 0
  (lembickit.md F15).
- Failed sends and pending Send Later messages no longer read as sent. A message
  the owner sent with a non-zero `error` ends with `[not delivered]`, and a Send
  Later message that has not gone out (`schedule_type` 2, `is_sent` 0) ends with
  `[scheduled, not sent]`. `MessageRecord.flags` marks both. A pending Send
  Later date no longer pins its conversation to the top of the list
  (lembickit.md F13, redaction.md F32).
- Messages no longer drop silently, and a body that does not decode is never
  shown as a normal message. A damaged `attributedBody` is salvaged up to the
  first missing byte, or the `text` column is used, and the line ends with
  `[message may be incomplete]`. With nothing to read, the line is
  `[message could not be read]`. An unknown `item_type` with text shows with
  `[unknown message type]`, and only the known system types (1 to 6) are
  skipped. A U+FFFC whose attachment row is gone shows `[attachment]`. The new
  `MessageRecord.flags` marks these rows. Rows that are not shown are counted:
  `Extractor.extract(_:chatIDs:)` returns them with the records, and
  `Export.Rendered.skipped` lists the ones in scope (lembickit.md F12,
  redaction.md F32).
- Attachments get the right type. A sticker shows `[sticker]`, a Genmoji shows
  `[genmoji: pink poodle]`, a dropped pin (`public.vlocation`, `.loc.vcf`) shows
  `[location]` instead of `[contact]`, and an m4a voice memo (`audio/mp4`) shows
  `[audio]` instead of `[video]`. `AttachmentInfo` has new `isSticker` and
  `emojiDescription` fields with defaulted init parameters (lembickit.md F11).
- Reactions on different parts of one message net apart. Removing a heart on
  the first photo of a grid no longer removes the laugh on the second photo
  (lembickit.md F10).
- Two different people with the same contact name no longer merge into one 1:1.
  `Conversations.group` takes a `contactIDs:` map and keys each person by their
  Contacts card, not by the name. A caller that passes only names gets one
  conversation per identifier (lembickit.md F9, bugs.md #6).
- Voice-note transcriptions show. A voice note with a transcription renders as
  `[audio: "This is a test"]` instead of `[audio]`. The decoder now reads the
  attribute runs after the message string (lembickit.md F8).
- Group events no longer tell a false story. A group photo or chat background
  change reads "X changed the group photo" (or removed it, or changed the chat
  background) instead of "X left", a member's number change reads "X changed
  their phone number" instead of "X added X", and unknown action values are
  skipped (lembickit.md F7).
- Sticker reactions and unknown reaction types no longer show as separate
  messages. A sticker tapback (2007, removed by 3007) and a sticker placed on a
  bubble (1000) attach to their target as `[Them: sticker]`. Any future tapback
  type (2000 to 2999) attaches with its own emoji or "•", and any other unknown
  `associated_message_type` is dropped, never shown with its quoted text
  (lembickit.md F6, redaction.md F32).
- Non-US contacts resolve to names. `buildContactInfo`, `resolve`, and
  `Conversations.list` take a `region:` that defaults to the new
  `ContactsMap.currentRegion()` (the Contacts setting, else the system region).
  `normalizePhone` strips the `00`, `011`, `0011`, and `010` exit codes, knows
  every calling code, keeps the trunk `0` in Italy, and applies the North American
  11-digit rule only in North America. A number saved in national form under the
  wrong country code matches on its last nine digits when exactly one card does
  (lembickit.md F5).
- App messages no longer vanish. Apple Pay, polls, Check In, games and other
  third-party apps, handwriting, and Digital Touch each render as one line read
  from `payload_data`, for example `[Apple Pay: Sent $20 with Apple Pay.]`. An
  app the engine cannot read shows `[app message]`. Poll votes attach to their
  poll like a reaction (`[Them: voted Tacos]`) (lembickit.md F4).
- Group stitching no longer merges different groups. Chats with different names
  never merge, even with the same members (for example "Book club" and "Lisbon
  trip"). When one roster has two names, its unnamed chats stay apart. The opt-in
  fuzzy pass also never merges two groups that were active at the same time, so
  a subgroup planning a surprise no longer folds into the main group
  (lembickit.md F1).
- One group no longer splits when a member uses a second handle. Stitching
  compares people, not handle rows: one number on iMessage, SMS, and RCS is one
  person, and so are handles linked by `person_centric_id` or by one Contacts
  card. Chats Apple links through `chat.group_id` or `chat_lookup` also join.
  Every handle of a person gets the same speaker label (lembickit.md F2).
- macOS 14 databases export again. The schema guard now fails closed only on the
  core columns the engine cannot work without (`ChatDatabase.requiredSchema` and
  `requiredBodyColumns`). Every other column is in the new
  `ChatDatabase.optionalSchema` and is probed at query time, so a missing one
  degrades one feature: for example, an emoji tapback without
  `associated_message_emoji` shows "•". `missingOptionalColumns()` lists the gaps
  (lembickit.md F3).

## [0.3.1] - 2026-06-19

### Security

- Unsent/retracted messages (Undo Send) are no longer exported. Rows with a
  non-zero `date_retracted` are dropped during extraction, so content the sender
  explicitly retracted never reaches the `.txt`/`.jsonl` output (#11).
- Overlapping or nested redaction spans no longer corrupt output or leak source
  text in `Transcript.redactedText(of:redactions:)`. Spans are now merged into a
  single covering `[redacted]` through the same splice path the `.txt`/`.jsonl`
  renderers use, so a span overlapping an already-redacted region can no longer
  expose source bytes (#8).
- The opt-in email scrubber regex no longer suffers catastrophic backtracking
  (ReDoS). The pattern is length-bounded (RFC label/address limits) and atomic,
  so a pathological hyphen-run that previously hung the render thread for seconds
  now completes in milliseconds (#7).
- The password and standing-code detectors no longer fire on ordinary prose
  (e.g. `password please`, `error code 500`, `area code 415`), holding the
  no-alert-fatigue floor. A real separator (`is`/`:`/`=`) is now required before
  a bare value, and `code` is gated by a negative-qualifier list (#5).

### Fixed

- The SSN detector no longer flags space-grouped 3-2-4 digit runs (e.g.
  `scores 123 45 6789 ok`) without a nearby `ssn`/`social security` keyword. The
  dashed form remains keyword-free (#6).
- `normalizePhone` no longer assumes US numbers. It accepts a configurable
  default region (ISO country code, defaulting to US), treats a leading `+` as
  authoritative, and strips a single national trunk `0`, so non-US contact names
  resolve and the phone+email identifier union holds for non-US contacts (#9).

## [0.3.0] - 2026-06-19

### Changed

- Removed `unsafeFlags` from the package manifest so LembicKit can be consumed as
  a normal versioned SwiftPM dependency (`.package(url:, from:)`). SwiftPM refuses
  to resolve any package that uses `unsafeFlags` against a version requirement, so
  this was previously only possible by branch or path. The `lembic-cli` target no
  longer embeds an Info.plist; its `--contacts` against the system Contacts store
  now falls back to plain numbers, while the `LEMBIC_CONTACTS` vCard path and the
  Lembic app are unaffected.

### Added

- `SECURITY.md` with the supported-version policy, private vulnerability
  reporting, and what does and does not count as a security problem.
- `CONTRIBUTING.md` covering local build and test, the checks CI runs, and the
  golden-file, schema-guard, and detector rules that matter most in review.
- This `CHANGELOG.md`, GitHub issue forms (bug report, feature request,
  unsupported database), an issue config, and a pull-request template.

### Fixed

- Removed two stray tags at the end of the README.

## [0.2.0] - 2026-06-17

### Changed

- LembicKit now opens `chat.db` in place, read-only, instead of copying it to a
  temporary file first. This removes the large temp copy (a real problem for
  multi-gigabyte databases) and reads the live write-ahead log, so an export
  reflects the messages currently on screen. A transient torn read during an
  active write is absorbed by a bounded retry.

### Added

- `ChatDatabase.messageDateBounds()` returns the oldest and newest real message
  timestamps, which lets a caller detect an incomplete local store (for example a
  Mac whose Messages-in-iCloud history has not finished syncing).

## [0.1.0] - 2026-06-17

### Added

- First public release of the LembicKit engine and the `lembic-cli` tool.
- Reads a macOS Messages `chat.db` and folds row-level chats into people-level
  conversations: a 1:1 conversation unions a person's identifiers (phone and
  email), and group chats stitch by exact participant set, with an opt-in fuzzy
  pass for changed membership.
- Renders LLM-ready transcripts: a compact, daily-grouped `.txt` and a
  one-object-per-message `.jsonl`, anchored to committed golden fixtures.
- On-device secret detection that flags high-harm secrets for review (passwords
  in context, SSNs, credit cards, seed phrases, API keys, standing codes, and
  bank account numbers) without ever flagging ordinary PII.
- Reversible redaction, plus opt-in scrubbers that auto-remove a chosen category
  (phone, postal address, email, one-time codes) through the same pipeline.
- Optional Contacts name resolution, with handle normalization.
- A schema-sanity guard that fails closed on an unsupported `chat.db` rather than
  producing a quietly wrong export.

[Unreleased]: https://github.com/darecstowell/LembicKit/compare/0.3.1...HEAD
[0.3.1]: https://github.com/darecstowell/LembicKit/compare/0.3.0...0.3.1
[0.3.0]: https://github.com/darecstowell/LembicKit/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/darecstowell/LembicKit/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/darecstowell/LembicKit/releases/tag/0.1.0
