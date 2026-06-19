# Contributing to LembicKit

Thanks for the interest. LembicKit does one job: read a macOS Messages `chat.db`
and turn a conversation into a transcript an LLM can read. Changes that sharpen
that job are welcome. Changes that grow it into a general backup or
device-management tool are a better fit somewhere else.

## Read CONTEXT.md before you write anything

`CONTEXT.md` is the map. It has the domain terms, a file-by-file table, and the
invariants that hold the engine together. Most review comments come back to
something written there, so start with it.

For anything non-trivial, open an issue before you write the code. That way we
agree on the direction before you spend time on it. Small, obvious fixes (a typo,
a clear bug with a test) can go straight to a pull request.

## Build and test locally

You need a Swift 6 toolchain (the package is `swift-tools-version: 6.0`) and
macOS 14 or later.

```sh
swift build
swift test
```

There is a synthetic example database in `Examples/`, so you can run the CLI
without Full Disk Access or any real data:

```sh
swift run lembic-cli conversations Examples/chat.db
swift run lembic-cli export Examples/chat.db --chat-id 6 --target-handles 6 --number +15035550146 --out-dir .
```

## Your pull request runs the same four checks CI runs

Run them before you push:

```sh
swift format lint --strict --recursive Sources      # formatting
swift build                                          # builds clean
swift test                                           # full suite, including the golden tests
swift run lembic-cli conversations Examples/chat.db  # CLI smoke test
```

To apply formatting instead of just checking it:

```sh
swift format --in-place --recursive Sources
```

## Three rules that catch most contributors

All three are covered in more depth in `CONTEXT.md`. They are the ones most
likely to fail review.

### Regenerate the golden files, never edit them by hand

`Transcript.compactText` and `jsonLines` output is pinned to committed reference
files in `Tests/LembicKitTests/Fixtures/`. The tests compare byte for byte. If
your change is meant to alter the output, regenerate the files instead of editing
them:

```sh
LEMBIC_REGOLD=1 swift test --filter golden   # rewrites the golden fixtures
git diff Tests/LembicKitTests/Fixtures        # read every byte of the change
```

Check that the diff is exactly the change you meant, then commit it. A surprising
golden diff in review is the sign that an output change was an accident.

### Keep the schema guard in lockstep

`ChatDatabase.requiredSchema` lists the exact tables and columns the engine's SQL
reads. If you add a column to a query, add it here too. The guard fails closed on
purpose: an unsupported `chat.db` should produce a visible error, not a quietly
wrong export.

### Detectors flag, scrubbers remove, and the floor is load-bearing

A detector only flags a high-harm secret for review. It removes nothing, and it
must never flag ordinary PII (bare phone numbers, emails, names, street
addresses). Burying a real secret in noise is the exact failure that floor
prevents.

A scrubber removes a whole category, but only when its toggle is on, and every
scrubber is off by default.

The "Extension points" section of `CONTEXT.md` walks through adding a detector, a
scrubber, or an output format. A new detector needs a false-positive test. A new
scrubber needs a default-off test.

## Opening a pull request

1. Fork and branch off `main`.
2. Keep it focused. One logical change per pull request.
3. Add or update tests. New behavior without a test is hard to accept.
4. Make the four checks above pass locally.
5. Write a clear description and link the issue it addresses.

## Contributions are MIT licensed; the name is not

By contributing, you agree to license your work under the project's
[MIT License](LICENSE). The name and logo are not covered by that license. See
[TRADEMARK](TRADEMARK) if you fork the project.

Be plain and kind in issues and pull requests. We want this to be an easy place
to contribute.
