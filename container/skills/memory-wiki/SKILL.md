---
name: memory-wiki
description: Deprecated — personal context has moved to the llm-wiki. Use when the agent needs to read personal context about Noah (projects, preferences, decisions). Redirects to llm-wiki.
---

# Memory Wiki (Deprecated)

Personal context has moved into the shared llm-wiki.

Read `wiki/personal/` inside the llm-wiki instead:

- `/workspace/extra/llm-wiki/wiki/personal/` — personal context pages (projects, preferences, people, ops)
- `/workspace/extra/llm-wiki/index.md` — full catalog including personal pages

If the llm-wiki mount is not present at `/workspace/extra/llm-wiki/`, tell the user the VM migration
hasn't been completed yet and point them to `deploy/migrate-memory-wiki.md`.
