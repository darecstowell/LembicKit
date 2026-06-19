# Security Policy

LembicKit reads a local Messages database and writes transcripts. It also runs
on-device secret detection and redaction. It handles private message content, so
security reports get taken seriously. Thank you for looking.

## Only the latest release gets security fixes

LembicKit is pre-1.0. The API and behavior can still change between minor
versions, so fixes land on the latest release only.

| Version            | Security fixes |
| ------------------ | -------------- |
| Latest 0.x release | Yes            |
| Anything older     | No             |

If you are on an older version, update to the latest release.

## Report a vulnerability privately, not in a public issue

Use GitHub's private vulnerability reporting. Open the repository **Security**
tab, then **Report a vulnerability**. The direct link is
https://github.com/darecstowell/LembicKit/security/advisories/new.

Give us enough to reproduce it: the affected version, a minimal input (a message
body or a small synthetic `chat.db`, never real private data), and what you saw
versus what you expected.

Here is what happens next:

- We acknowledge the report within 3 business days.
- We send a first assessment (accepted, need more detail, or out of scope) within
  about a week.
- If we accept it, we fix it, ship a release, and credit you in the advisory
  unless you would rather we did not.

## What we treat as a security problem

These are the failures that would actually expose someone, given what the library
does:

- A redacted or scrubbed value still shows up in the rendered `.txt` or `.jsonl`
  output. Overlapping spans and offset-map errors are the usual causes.
- A high-harm secret in an enabled category is not flagged when it plainly should
  be, in a way that defeats the flag-for-review guarantee.
- Any code path that sends message content off the machine. The library is meant
  to have no network code, so if you find some, tell us.
- Any read or write outside the read-only open of the given `chat.db`: writing to
  it, touching other files, or escaping the read-only contract.
- Input that hangs the renderer or a detector, or drives unbounded memory use.
  Catastrophic regular-expression backtracking over a message body is the case to
  watch.

## What is not a security problem

These are by design, or we handle them as ordinary issues. Please do not file
them as security reports:

- Detectors not flagging ordinary PII. Bare phone numbers, emails, names, and
  street addresses are never flagged, on purpose. That floor keeps a real secret
  from being buried in noise, and it is documented in `CONTEXT.md`.
- False positives, or false negatives that do not leak a secret into the output.
  File a normal issue with a reproducing input.
- The need for Full Disk Access to read `chat.db`. That is an OS permission, not a
  flaw here.
- Bugs in third-party dependencies. Report those upstream. We will pick up the
  fixed version.

When you are not sure, report it privately and let us sort it out. A report that
turns out to be in the second list is better than a real one we never hear about.
