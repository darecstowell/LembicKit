# Example data

A fully synthetic Messages database and a matching vCard, so you can run `lembic-cli` without touching your real messages. Nothing here is real: every name, number, and message is fabricated, and the phone numbers are all in the `555-01xx` range reserved for fiction.

| File | What it is |
|---|---|
| `chat.db` | A synthetic Messages database with eleven 1:1 conversations of varying length. |
| `contacts.vcf` | A vCard whose phone and email handles line up with `chat.db`, for name resolution. |

It ships as a committed fixture, so the commands below work straight from a clone.

## List the conversations

```sh
swift run lembic-cli conversations Examples/chat.db
```

Each row shows the `chat-id` and `target-handles` you pass to `export`.

## Export one conversation

```sh
swift run lembic-cli export Examples/chat.db \
  --chat-id 6 --target-handles 6 --number +15035550146 --out-dir .
```

This writes `messages_<number>.txt` and `messages_<number>.jsonl` to the current directory.

## Resolve names

Point `LEMBIC_CONTACTS` at the vCard to label people by name instead of number, with no Contacts permission prompt:

```sh
LEMBIC_CONTACTS=Examples/contacts.vcf swift run lembic-cli conversations Examples/chat.db --contacts
```
