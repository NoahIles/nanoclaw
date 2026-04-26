---
name: add-karpathy-llm-wiki
description: Add a persistent wiki knowledge base to NanoClaw and/or local Claude Code. Based on Karpathy's LLM Wiki pattern. Triggers on "add wiki", "wiki", "knowledge base", "llm wiki", "karpathy wiki".
---

# Add Karpathy LLM Wiki

Set up a persistent, git-backed wiki knowledge base based on Karpathy's LLM Wiki pattern.
The wiki is shared across local Claude Code and NanoClaw container agents via a bare git repo.

## Step 1: Read the pattern

Read `${CLAUDE_SKILL_DIR}/llm-wiki.md` — the full LLM Wiki idea as written by Karpathy.
Summarize the core idea to the user briefly, then proceed.

## Step 2: Choose deployment context

AskUserQuestion: "Where will the wiki be used?"

1. **Shared — Claude Code + NanoClaw (Recommended)** — one canonical wiki, bidirectionally
   writable from both your local Claude Code sessions and NanoClaw container agents. Backed by
   a bare git repo on the VM, synced automatically via Stop hooks and cron.
2. **NanoClaw only** — wiki lives inside an agent group folder; only NanoClaw agents read/write it.
3. **Claude Code only** — wiki lives at `~/.claude/llm-wiki/` locally; no NanoClaw involvement.

---

## Path A: Shared (Claude Code + NanoClaw)

### A1. Design the wiki

Ask the user:
- What domain or topic is this wiki for?
- What source types will they add? (URLs, PDFs, images, voice notes, books, transcripts)

### A2. Bootstrap the shared repo

Check whether `~/.claude/llm-wiki/` already exists:

```bash
ls ~/.claude/llm-wiki/.git 2>/dev/null && echo "exists" || echo "not found"
```

**If not found:** Run the installer with the `--with-llm-wiki` flag. This prompts for the VM
SSH target and bare repo path, creates the bare repo, pushes an initial skeleton, clones to
`~/.claude/llm-wiki/`, writes `~/.config/nanoclaw/llm-wiki-sync.conf`, and wires the Stop hook.

```bash
bash scripts/install-stop-hook.sh --with-llm-wiki
```

**If already found:** The bare repo, local clone, and Stop hook are already set up. Skip to A3.

### A3. Wire the NanoClaw side

**3a. VM working clone**

Ensure `/opt/nanoclaw/llm-wiki/` exists on the VM:

```bash
# SSH to the VM and check
ssh <user@host> 'ls /opt/nanoclaw/llm-wiki/.git 2>/dev/null && echo "exists" || echo "not found"'
```

If not found, clone on the VM:
```bash
ssh <user@host> 'git clone /srv/git/llm-wiki.git /opt/nanoclaw/llm-wiki'
```

**3b. Mount allowlist**

Edit `~/.config/nanoclaw/mount-allowlist.json` on the host running NanoClaw. Add an entry:

```json
{
  "path": "/opt/nanoclaw/llm-wiki",
  "allowReadWrite": true
}
```

The validator (`src/modules/mount-security/index.ts`) requires this AND `readonly: false` in
`container.json` to grant the agent write access.

**3c. Choose a group**

AskUserQuestion: "Which NanoClaw group should have wiki access?"

1. **Existing main group** — add to your existing primary agent group
2. **Existing other group** — pick from current groups
3. **New dedicated group** — create a new group just for the wiki

If new: register it with `pnpm exec tsx setup/index.ts --step register`.

**3d. Update container.json**

Edit the group's `container.json` to add the wiki mount:

```json
{
  "additionalMounts": [
    {
      "hostPath": "/opt/nanoclaw/llm-wiki",
      "containerPath": "llm-wiki",
      "readonly": false
    }
  ]
}
```

The container path `llm-wiki` becomes `/workspace/extra/llm-wiki/` inside the agent.

**3e. Enable the llm-wiki container skill**

The `llm-wiki` skill is in `container/skills/llm-wiki/`. Add it to the group's skill list.

If the group's `container.json` uses `"skills": "all"`, it is already included.

If it uses an explicit list, add `"llm-wiki"` to the array.

**3f. Update the group's CLAUDE.md**

Add this section to the group's `CLAUDE.md`:

```markdown
## LLM Wiki

The wiki at `/workspace/extra/llm-wiki/` is a shared knowledge base (Karpathy pattern).
It is writable — the agent maintains it by ingesting sources, answering queries against it,
and running periodic lint passes.

Run `/llm-wiki` for the full workflow. Key rules:
- **Always pull before reading or editing** (`git pull --ff-only`)
- **Always commit + push after any edit** (`git add -A && git commit -m '...' && git push`)
- Process one source at a time — never batch-ingest
```

**3g. VM safety-net cron**

On the VM, add the llm-wiki cron from `deploy/crontab.vm` if not already present:

```bash
ssh <user@host> 'crontab -l 2>/dev/null | grep -q llm-wiki && echo "already installed" || echo "not installed"'
```

If not installed, append it:
```bash
ssh <user@host> "crontab -l 2>/dev/null; echo '*/5 * * * * test -d /opt/nanoclaw/llm-wiki/.git && cd /opt/nanoclaw/llm-wiki && git pull --ff-only --quiet && git add -A && { git diff --cached --quiet || git commit -m \"vm-sync \$(date -Iseconds)\" --quiet; } && git push --quiet >> /opt/nanoclaw/logs/llm-wiki-sync.log 2>&1'" | ssh <user@host> crontab -
```

Or just run `crontab -e` on the VM and add the line from `deploy/crontab.vm`.

### A4. Source handling capabilities

Ask which source types the user plans to add. The agent has `WebFetch` and `agent-browser`
built in. For PDFs and images: natively supported. For voice: `/add-voice-transcription` skill.

Note: For full-text ingestion of URLs, use `curl` or `agent-browser` rather than `WebFetch`
(which summarizes). The container skill covers this.

### A5. Optional lint schedule

AskUserQuestion: "Want periodic wiki health checks?"

1. **Weekly**
2. **Monthly**
3. **Skip** — lint manually

If yes, tell the user to send this message to their wiki agent after setup is complete:

> "Please schedule a recurring wiki lint check — [weekly on Sunday mornings / monthly on the 1st].
> Check for contradictions, orphan pages, stale content, missing cross-references, and gaps.
> Report findings and offer to fix issues."

The agent will create the recurring task using the `schedule_task` MCP tool.

### A6. Build and restart

```bash
pnpm run build
./container/build.sh
systemctl --user restart nanoclaw  # Linux
# launchctl kickstart -k gui/$(id -u)/com.nanoclaw  # macOS
```

Tell the user to test by sending a source URL or file to the wiki group.

---

## Path B: NanoClaw only

The wiki lives inside the group folder (not shared with Claude Code).

### B1. Design the wiki (same as A1)

### B2. Choose a group

AskUserQuestion: same as A3c above.

### B3. Create wiki directory structure

In the group folder, create `wiki/` and `sources/` with initial skeleton files:

```bash
mkdir -p groups/<group>/wiki groups/<group>/sources
```

Create `groups/<group>/wiki/index.md`:
```markdown
# Wiki Index
_No pages yet._
```

Create `groups/<group>/wiki/log.md`:
```markdown
# Wiki Log
---
```

### B4. Create container skill

Create `container/skills/wiki-<group>/SKILL.md` tailored to this group's domain.
Base it on `container/skills/llm-wiki/SKILL.md` but:
- Change paths from `/workspace/extra/llm-wiki/` to `/workspace/group/wiki/` and `/workspace/group/sources/`
- Remove the git pull/push steps (files are written directly to the group folder; no sync needed)

### B5. Update the group's CLAUDE.md (same wiki section as A3f, adapted for local paths)

### B6. Optional lint schedule (same as A5, NanoClaw agent via schedule_task)

### B7. Build and restart (same as A6)

---

## Path C: Claude Code only

The wiki lives at `~/.claude/llm-wiki/` locally; no NanoClaw involvement.

### C1. Design the wiki (same as A1)

### C2. Bootstrap local repo

```bash
mkdir -p ~/.claude/llm-wiki/wiki ~/.claude/llm-wiki/sources
cd ~/.claude/llm-wiki
git init
git checkout -b main
```

Create `~/.claude/llm-wiki/CLAUDE.md`, `index.md`, and `log.md` with the standard skeleton
content from `scripts/install-stop-hook.sh` (the llm-wiki bootstrap section).

Commit the skeleton:
```bash
git -C ~/.claude/llm-wiki add -A
git -C ~/.claude/llm-wiki commit -m "init: llm-wiki skeleton"
```

If the user has a remote (GitHub, Gitea, bare repo on a server), wire it:
```bash
git -C ~/.claude/llm-wiki remote add origin <remote>
git -C ~/.claude/llm-wiki push -u origin main
```

### C3. Wire Stop hook (optional but recommended)

If `scripts/sync-llm-wiki.sh` and `~/.config/nanoclaw/llm-wiki-sync.conf` are not yet set up:

Write the config:
```bash
mkdir -p ~/.config/nanoclaw
echo "LLM_WIKI_REMOTE=<remote-or-skip>" > ~/.config/nanoclaw/llm-wiki-sync.conf
```

Wire the Stop hook (idempotent):
```bash
SCRIPT_PATH="$(pwd)/scripts/sync-llm-wiki.sh"
SETTINGS="$HOME/.claude/settings.json"
existing=$(cat "$SETTINGS" 2>/dev/null || echo '{}')
hook_entry=$(jq -n --arg cmd "$SCRIPT_PATH" \
  '[{"matcher":"","hooks":[{"type":"command","command":$cmd,"timeout":15,"async":true}]}]')
echo "$existing" | jq --argjson h "$hook_entry" \
  '.hooks.Stop = ((.hooks.Stop // []) + $h)' > "$SETTINGS"
```

### C4. Add wiki reference to CLAUDE.md

Add a section to this project's `CLAUDE.md` (or `~/.claude/CLAUDE.md` globally) pointing
Claude Code at the wiki:

```markdown
## LLM Wiki

Wiki at `~/.claude/llm-wiki/`. Pull → read → edit → commit → push for every change.
Read `~/.claude/llm-wiki/index.md` before answering questions within the wiki's domain.
```

### C5. Optional lint schedule

Use `CronCreate` (Claude Code built-in) for recurring lint prompts, or lint manually on demand.
