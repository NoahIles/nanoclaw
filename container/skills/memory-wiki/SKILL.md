---
name: memory-wiki
description: Use and maintain the claude-memory wiki — a curated, human-readable knowledge base synced across Noah's devices. Covers how to read the wiki, fall back to mempalace, and propose updates.
---

# Memory Wiki

The wiki at `/workspace/extra/memory/` is a curated knowledge base about Noah, his projects,
recurring preferences, and decisions. It's synced from his local machines via git — what
you read here is current as of the last session.

It is **read-only** inside the container. You can read any file; you cannot write them.

---

## Reading the wiki

1. Open `/workspace/extra/memory/index.md` — the catalog. It lists every page with a one-line
   summary. Start here before drilling in.
2. Follow the linked page paths. Pages are small markdown files; read the ones relevant
   to the question.
3. `log.md` is append-only history — useful if you want to understand what was recently
   added or discussed.

**Do this automatically** whenever the user asks something that likely depends on past
context: who Noah is, his projects, tools he uses, decisions he's made, recurring tasks,
preferences, or people he's mentioned.

---

## Falling back to mempalace

If the wiki doesn't have an answer, call the `mempalace` MCP tools (search, query) to
retrieve raw conversation history. Mempalace has everything ever said; the wiki has the
curated highlights. They complement each other.

Useful pattern:
- Wiki first (fast, synthesized, curated)
- Mempalace fallback (broad, raw, comprehensive)
- Tell Noah which source you used

---

## Proposing wiki updates

When you find something worth adding — a new preference, a decision, a project update,
a person — **propose it in chat rather than writing it yourself**. The mount is read-only,
so a direct write attempt will fail anyway, but more importantly: proposed updates let
Noah review before they land in his permanent knowledge base.

Format your proposal like this:

```
I'd suggest adding this to the wiki:

**File:** `projects/nanoclaw.md` (new section under "Deployment")
**Content:**
> Deployed to Proxmox VM at 192.168.x.x. Docker Compose stack: mempalace, backup.
> OneCLI runs natively on the host. Caddy LXC handles TLS termination.

Want me to draft the full edit?
```

Noah will apply it locally. It'll sync to you within 5 minutes via cron pull.

---

## Wiki structure

```
memory/
├── CLAUDE.md     # this schema (how to maintain)
├── index.md      # catalog of all pages + one-line summaries
├── log.md        # append-only log of additions and edits
├── people/       # entity pages (noah.md, contacts, etc.)
├── projects/     # per-project pages
├── concepts/     # topic / domain knowledge
└── ops/          # how-tos and runbooks
```

---

## If the wiki doesn't exist yet

`/workspace/extra/memory/` may be empty or missing the index. That just means it hasn't
been set up yet — don't error out. Mention to Noah that the memory wiki isn't populated
and offer to help draft the initial skeleton if he'd like.
