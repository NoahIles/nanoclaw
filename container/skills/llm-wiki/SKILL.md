---
name: llm-wiki
description: Use when the user references the wiki, asks to ingest a source, query the knowledge base, or run a lint pass. Covers read, write, ingest, query, and lint operations for the shared git-backed LLM wiki.
---

# LLM Wiki

The wiki is a Karpathy-pattern persistent knowledge base shared with local Claude Code.
It lives at `/workspace/extra/llm-wiki/` (mounted read-write from the VM clone).

---

## Always pull before reading or writing

```bash
git -C /workspace/extra/llm-wiki pull --ff-only --quiet
```

If this fails (not fast-forwardable), **stop**. Tell the user there's a diverged branch and ask them to resolve it manually — do not attempt an automatic merge.

## Always commit and push after any edit

```bash
git -C /workspace/extra/llm-wiki add -A
git -C /workspace/extra/llm-wiki commit -m "<concise summary of what changed>"
git -C /workspace/extra/llm-wiki push --quiet
```

---

## Wiki layout

```
llm-wiki/
├── CLAUDE.md    # this schema (same file seen by Claude Code)
├── index.md     # catalog — read this first on every query
├── log.md       # append-only history (## [YYYY-MM-DD] operation | title)
├── wiki/        # LLM-generated pages
└── sources/     # raw immutable source material
```

---

## Operations

### Ingest

1. Pull (always first)
2. Download the source to `sources/` — use `curl` for binaries, `agent-browser` for webpages
3. Read the source carefully
4. Discuss key takeaways with the user
5. Create or update wiki pages: summary page, entity pages, concept pages, cross-references
6. Update `index.md` (add new pages, update summaries of changed pages)
7. Append a log entry to `log.md`: `## [YYYY-MM-DD] ingest | <source title>`
8. Commit + push

**One source at a time.** Never batch-read multiple sources and process them together — this
produces shallow, generic pages. Fully finish one source (all wiki edits, index, log, commit)
before moving to the next.

**Downloading sources:**
```bash
# PDF or binary file
curl -sLo /workspace/extra/llm-wiki/sources/filename.pdf "<url>"

# Webpage: use agent-browser to get full text
agent-browser open <url>
agent-browser snapshot
# then save the extracted text to sources/
```

### Query

1. Pull (always first)
2. Read `index.md` to locate relevant pages
3. Read those pages
4. Synthesize answer with citations (page names + relevant quotes)
5. If the answer is a useful synthesis worth keeping, offer to save it as a new wiki page

### Lint

1. Pull (always first)
2. Read `index.md` and scan all pages
3. Check for:
   - Contradictions between pages
   - Orphan pages (no inbound links from other pages or index)
   - Stale content superseded by newer sources
   - Missing cross-references
   - Important entities or concepts without dedicated pages
   - Gaps in coverage the user might want to fill
4. Report findings. Offer to fix issues one at a time.
5. Commit + push after fixes

---

## Index format

Keep `index.md` organized by category. Each entry: `- [Page title](path) — one-line summary`

## Log format

Each entry: `## [YYYY-MM-DD] <operation> | <title>`
Operations: `ingest`, `query`, `lint`, `edit`

Grep for recent activity:
```bash
grep "^## \[" /workspace/extra/llm-wiki/log.md | tail -10
```
