# Golden set

Messy transcripts paired with the output the prompt compiler must produce. Every prompt change
runs these (phase 2). Add a case whenever a real dictation goes wrong.

Fields:

- `id` — unique, kebab-case, doubles as the file name
- `destination` — `claude_code | cursor | codex | chat | message | email | document | shell`
- `level` — `VERBATIM | LIGHT | MEDIUM | FULL`
- `transcript` — what the speech recogniser produced, fillers and all
- `expected` — the exact output
- `mustContain` — identifiers, paths or names that must survive spelled this way
- `notes` — why this case exists

Rules the expected outputs follow: nothing unspoken is added, questions stay questions, the
speaker's register is kept, plain text only for coding agents.
