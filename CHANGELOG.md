# Changelog

All notable changes to LembicKit are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

LembicKit is pre-1.0, so minor versions can still carry breaking API changes.

## [Unreleased]

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
