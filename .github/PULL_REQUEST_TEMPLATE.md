## What this changes

Describe the change and why it is needed. Link the issue it addresses
(for example, Closes #123).

## Checklist

- [ ] The four CI checks pass locally (`swift format lint --strict --recursive Sources`, `swift build`, `swift test`, and the CLI smoke test).
- [ ] Tests are added or updated for the change.
- [ ] If the rendered output changed on purpose, the golden files were regenerated (`LEMBIC_REGOLD=1 swift test --filter golden`) and the diff was reviewed.
- [ ] If a SQL query reads a new column, it was added to `ChatDatabase.requiredSchema`.
- [ ] A new detector does not flag ordinary PII and has a false-positive test; a new scrubber defaults to off and has a default-off test.
