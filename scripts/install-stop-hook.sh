#!/bin/bash
# install-stop-hook.sh — Wire the Claude Code Stop hook for MemPalace sync
# and the claude-memory wiki git sync.
#
# What this does:
#   1. Prompts for the VM SSH target (user@host:/opt/nanoclaw/imports/claude-code)
#   2. Tests SSH + rsync connectivity
#   3. Writes ~/.config/nanoclaw/mempalace-sync.conf (incl. MEMORY_GIT_REMOTE)
#   4. Merges Stop hook entries into ~/.claude/settings.json (idempotent):
#      — sync-to-mempalace.sh (JSONL rsync, async)
#      — sync-memory.sh       (memory wiki git sync, async)
#      — sync-llm-wiki.sh     (llm-wiki git sync, async — only with --with-llm-wiki)
#   5. Bootstraps the bare memory repo on the VM + local clone (if first run)
#   6. Optionally bootstraps the llm-wiki bare repo + local clone (--with-llm-wiki)
#   7. Prints the .mcp.json entry needed for MemPalace in Claude Code
#
# Flags:
#   --dry-run        Preview the settings.json merge without writing.
#   --with-llm-wiki  Also set up the shared bidirectional llm-wiki (Karpathy pattern).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETTINGS_FILE="${HOME}/.claude/settings.json"
CONF_DIR="${HOME}/.config/nanoclaw"
CONF_FILE="${CONF_DIR}/mempalace-sync.conf"
LLM_WIKI_CONF_FILE="${CONF_DIR}/llm-wiki-sync.conf"
SYNC_SCRIPT="${REPO_ROOT}/scripts/sync-to-mempalace.sh"
MEMORY_SYNC_SCRIPT="${REPO_ROOT}/scripts/sync-memory.sh"
LLM_WIKI_SYNC_SCRIPT="${REPO_ROOT}/scripts/sync-llm-wiki.sh"
MEMORY_DIR="${HOME}/.claude/memory"
LLM_WIKI_DIR="${HOME}/.claude/llm-wiki"
DRY_RUN=false
WITH_LLM_WIKI=false

# ── Helpers ───────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}!${NC} $*"; }
error()   { echo -e "${RED}✗${NC} $*" >&2; }
heading() { echo -e "\n${BOLD}$*${NC}"; }
die()     { error "$*"; exit 1; }

# ── Parse args ────────────────────────────────────────────────────────────────

for arg in "$@"; do
  case "$arg" in
    --dry-run)       DRY_RUN=true ;;
    --with-llm-wiki) WITH_LLM_WIKI=true ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

if $DRY_RUN; then
  warn "Dry-run mode — no files will be written"
fi

# ── Preflight ─────────────────────────────────────────────────────────────────

heading "Checking dependencies"

command -v jq   >/dev/null 2>&1 || die "jq is required: brew install jq / apt install jq"
command -v rsync >/dev/null 2>&1 || die "rsync is required: brew install rsync / apt install rsync"
command -v ssh  >/dev/null 2>&1 || die "ssh is required"

info "jq, rsync, ssh found"

# ── Prompt for SSH target ─────────────────────────────────────────────────────

heading "VM SSH target"

existing_target=""
existing_memory_remote=""
if [[ -f "$CONF_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONF_FILE"
  existing_target="${MEMPALACE_SSH_TARGET:-}"
  existing_memory_remote="${MEMORY_GIT_REMOTE:-}"
fi

if [[ -n "$existing_target" ]]; then
  echo "Current target: ${BOLD}${existing_target}${NC}"
  read -rp "Press Enter to keep, or enter a new target: " input
  SSH_TARGET="${input:-$existing_target}"
else
  echo "Enter the SSH destination for Claude Code JSONL files."
  echo "Format: user@host:/opt/nanoclaw/imports/claude-code"
  read -rp "SSH target: " SSH_TARGET
fi

[[ -z "$SSH_TARGET" ]] && die "SSH target cannot be empty"

# Parse host and path
SSH_HOST="${SSH_TARGET%%:*}"
REMOTE_PATH="${SSH_TARGET#*:}"

# ── Test connectivity ─────────────────────────────────────────────────────────

heading "Testing SSH connectivity"

if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$SSH_HOST" "mkdir -p '$REMOTE_PATH'" 2>/dev/null; then
  warn "SSH test failed. Make sure:"
  warn "  • SSH key is installed: ssh-copy-id $SSH_HOST"
  warn "  • VM is reachable on your LAN/VPN"
  read -rp "Continue anyway? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted"
else
  info "SSH connection OK, remote path created"
fi

# ── Write config ──────────────────────────────────────────────────────────────

heading "Writing sync config"

# Derive default memory remote from SSH host + standard bare repo path
DEFAULT_MEMORY_REMOTE="${SSH_HOST}:/srv/git/claude-memory.git"
if [[ -n "$existing_memory_remote" ]]; then
  echo "Current memory remote: ${BOLD}${existing_memory_remote}${NC}"
  read -rp "Press Enter to keep, or enter a new remote: " mem_input
  MEMORY_GIT_REMOTE="${mem_input:-$existing_memory_remote}"
else
  echo "Memory wiki git remote (bare repo on the VM)."
  echo "Default: ${DEFAULT_MEMORY_REMOTE}"
  read -rp "Press Enter to accept default, or enter a custom remote: " mem_input
  MEMORY_GIT_REMOTE="${mem_input:-$DEFAULT_MEMORY_REMOTE}"
fi

if $DRY_RUN; then
  warn "[dry-run] Would write to $CONF_FILE:"
  echo "  MEMPALACE_SSH_TARGET=${SSH_TARGET}"
  echo "  MEMORY_GIT_REMOTE=${MEMORY_GIT_REMOTE}"
else
  mkdir -p "$CONF_DIR"
  chmod 700 "$CONF_DIR"
  cat > "$CONF_FILE" <<EOF
# Written by install-stop-hook.sh — edit with care
MEMPALACE_SSH_TARGET=${SSH_TARGET}
MEMORY_GIT_REMOTE=${MEMORY_GIT_REMOTE}
EOF
  chmod 600 "$CONF_FILE"
  info "Config written to $CONF_FILE"
fi

# ── Merge Stop hooks into settings.json ──────────────────────────────────────

heading "Wiring Claude Code Stop hooks"

# Read existing settings or start with empty object
if [[ -f "$SETTINGS_FILE" ]]; then
  existing=$(cat "$SETTINGS_FILE")
else
  existing="{}"
fi

wire_stop_hook() {
  local script="$1"
  local label="$2"
  local hook_entry
  hook_entry=$(jq -n \
    --arg cmd "$script" \
    '[{"matcher": "", "hooks": [{"type": "command", "command": $cmd, "timeout": 15, "async": true}]}]')

  local already_wired
  already_wired=$(echo "$existing" | jq --arg cmd "$script" \
    '.hooks.Stop // [] | map(.hooks // [] | map(.command == $cmd)) | flatten | any')

  if [[ "$already_wired" == "true" ]]; then
    info "$label Stop hook already wired"
  else
    existing=$(echo "$existing" | jq \
      --argjson hook "$hook_entry" \
      '.hooks.Stop = ((.hooks.Stop // []) + $hook)')
    if $DRY_RUN; then
      warn "[dry-run] Would add $label Stop hook"
    else
      info "$label Stop hook queued"
    fi
  fi
}

wire_stop_hook "$SYNC_SCRIPT" "MemPalace sync"
wire_stop_hook "$MEMORY_SYNC_SCRIPT" "Memory wiki sync"

if $WITH_LLM_WIKI; then
  wire_stop_hook "$LLM_WIKI_SYNC_SCRIPT" "LLM wiki sync"
fi

if ! $DRY_RUN; then
  echo "$existing" > "$SETTINGS_FILE"
  info "Stop hooks written to $SETTINGS_FILE"
else
  warn "[dry-run] Would write to $SETTINGS_FILE:"
  echo "$existing" | jq '.hooks.Stop'
fi

# ── Bootstrap memory repo on VM + local clone ─────────────────────────────────

heading "Memory wiki setup"

MEMORY_GIT_HOST="${MEMORY_GIT_REMOTE%%:*}"
MEMORY_GIT_PATH="${MEMORY_GIT_REMOTE#*:}"

if [[ -d "$MEMORY_DIR/.git" ]]; then
  info "Memory repo already cloned at $MEMORY_DIR"
else
  # Check if bare repo exists on VM; create it if not
  bare_exists=false
  if ssh -o ConnectTimeout=5 -o BatchMode=yes "$MEMORY_GIT_HOST" \
      "test -d '$MEMORY_GIT_PATH'" 2>/dev/null; then
    bare_exists=true
  fi

  if ! $bare_exists; then
    if $DRY_RUN; then
      warn "[dry-run] Would create bare repo at $MEMORY_GIT_REMOTE"
    else
      info "Creating bare repo at $MEMORY_GIT_REMOTE"
      ssh -o ConnectTimeout=5 "$MEMORY_GIT_HOST" \
        "mkdir -p '$(dirname "$MEMORY_GIT_PATH")' && git init --bare '$MEMORY_GIT_PATH'"

      # Bootstrap skeleton: init a temp repo, push initial commit to bare
      TMPDIR_REPO="$(mktemp -d)"
      trap 'rm -rf "$TMPDIR_REPO"' EXIT
      git -C "$TMPDIR_REPO" init --quiet
      git -C "$TMPDIR_REPO" checkout -b main --quiet

      # Write skeleton files
      cat > "$TMPDIR_REPO/index.md" <<'MDEOF'
# Memory Index

This is Noah's curated knowledge wiki. It is maintained by Claude Code and NanoClaw agents.
New entries are proposed in chat and committed locally, then synced to all devices via git.

## Pages

_No pages yet. As you work with Claude, important facts and decisions will be proposed for
inclusion here. Accept them to grow the wiki._
MDEOF

      cat > "$TMPDIR_REPO/log.md" <<'MDEOF'
# Memory Log

Append-only record of additions and significant edits to the wiki.

---
MDEOF

      cat > "$TMPDIR_REPO/CLAUDE.md" <<'MDEOF'
# claude-memory Wiki Schema

This directory is a curated knowledge wiki about Noah, his projects, preferences, and decisions.
It is synced across devices via git. Agent containers read it at `/workspace/extra/memory/` (read-only).
Claude Code reads it at `~/.claude/memory/`.

## Structure

- `index.md` — catalog of all pages with one-line summaries, organized by category
- `log.md` — append-only chronological record of wiki additions and edits
- `people/` — entity pages (noah.md, contacts, recurring people)
- `projects/` — per-project pages
- `concepts/` — topic/domain knowledge
- `ops/` — how-tos, runbooks, recurring procedures

## Rules

1. **Index first.** Read `index.md` before answering questions about Noah's context.
2. **Read-only in containers.** The mount is RO inside NanoClaw agent containers.
   Propose edits in chat; Noah commits them locally.
3. **Mempalace fallback.** If the wiki doesn't have an answer, use the mempalace MCP
   tools to search raw conversation history.
4. **Propose, don't fabricate.** When you find something memory-worthy, propose a
   concrete wiki edit (file path + content) in chat. Keep it brief.
5. **No stale facts.** Prefix uncertain claims with "as of <date>:" and flag them
   for Noah to verify.

## Proposing an edit

Format your proposal so Noah can apply it in one step:

```
Wiki update proposal:

File: projects/nanoclaw.md (new section)
---
## Deployment
Deployed to Proxmox VM. Docker Compose: mempalace, backup. OneCLI on host.
---
```
MDEOF

      mkdir -p "$TMPDIR_REPO/people" "$TMPDIR_REPO/projects" \
               "$TMPDIR_REPO/concepts" "$TMPDIR_REPO/ops"

      touch "$TMPDIR_REPO/people/.gitkeep" \
            "$TMPDIR_REPO/projects/.gitkeep" \
            "$TMPDIR_REPO/concepts/.gitkeep" \
            "$TMPDIR_REPO/ops/.gitkeep"

      git -C "$TMPDIR_REPO" add -A
      git -C "$TMPDIR_REPO" -c user.name="nanoclaw" \
          -c user.email="nanoclaw@local" \
          commit -m "init: memory wiki skeleton" --quiet
      git -C "$TMPDIR_REPO" remote add origin "$MEMORY_GIT_REMOTE"
      git -C "$TMPDIR_REPO" push origin main --quiet
      info "Skeleton committed and pushed to bare repo"
    fi
  fi

  if ! $DRY_RUN; then
    info "Cloning memory wiki to $MEMORY_DIR"
    git clone "$MEMORY_GIT_REMOTE" "$MEMORY_DIR" --quiet
    info "Memory wiki ready at $MEMORY_DIR"
  else
    warn "[dry-run] Would clone $MEMORY_GIT_REMOTE → $MEMORY_DIR"
  fi
fi

# ── LLM wiki setup (optional, --with-llm-wiki) ───────────────────────────────

if $WITH_LLM_WIKI; then
  heading "LLM wiki setup"

  DEFAULT_LLM_WIKI_REMOTE="${SSH_HOST}:/srv/git/llm-wiki.git"
  existing_llm_wiki_remote=""
  if [[ -f "$LLM_WIKI_CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$LLM_WIKI_CONF_FILE"
    existing_llm_wiki_remote="${LLM_WIKI_REMOTE:-}"
  fi

  if [[ -n "$existing_llm_wiki_remote" ]]; then
    echo "Current llm-wiki remote: ${BOLD}${existing_llm_wiki_remote}${NC}"
    read -rp "Press Enter to keep, or enter a new remote: " wiki_input
    LLM_WIKI_REMOTE="${wiki_input:-$existing_llm_wiki_remote}"
  else
    echo "LLM wiki git remote (bare repo on the VM)."
    echo "Default: ${DEFAULT_LLM_WIKI_REMOTE}"
    read -rp "Press Enter to accept default, or enter a custom remote: " wiki_input
    LLM_WIKI_REMOTE="${wiki_input:-$DEFAULT_LLM_WIKI_REMOTE}"
  fi

  if $DRY_RUN; then
    warn "[dry-run] Would write to $LLM_WIKI_CONF_FILE: LLM_WIKI_REMOTE=${LLM_WIKI_REMOTE}"
  else
    mkdir -p "$CONF_DIR"
    chmod 700 "$CONF_DIR"
    cat > "$LLM_WIKI_CONF_FILE" <<EOF
# Written by install-stop-hook.sh --with-llm-wiki — edit with care
LLM_WIKI_REMOTE=${LLM_WIKI_REMOTE}
EOF
    chmod 600 "$LLM_WIKI_CONF_FILE"
    info "Config written to $LLM_WIKI_CONF_FILE"
  fi

  LLM_WIKI_GIT_HOST="${LLM_WIKI_REMOTE%%:*}"
  LLM_WIKI_GIT_PATH="${LLM_WIKI_REMOTE#*:}"

  if [[ -d "$LLM_WIKI_DIR/.git" ]]; then
    info "LLM wiki already cloned at $LLM_WIKI_DIR"
  else
    llm_wiki_bare_exists=false
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$LLM_WIKI_GIT_HOST" \
        "test -d '$LLM_WIKI_GIT_PATH'" 2>/dev/null; then
      llm_wiki_bare_exists=true
    fi

    if ! $llm_wiki_bare_exists; then
      if $DRY_RUN; then
        warn "[dry-run] Would create bare repo at $LLM_WIKI_REMOTE"
      else
        info "Creating bare repo at $LLM_WIKI_REMOTE"
        ssh -o ConnectTimeout=5 "$LLM_WIKI_GIT_HOST" \
          "mkdir -p '$(dirname "$LLM_WIKI_GIT_PATH")' && git init --bare '$LLM_WIKI_GIT_PATH'"

        TMPDIR_WIKI="$(mktemp -d)"
        trap 'rm -rf "$TMPDIR_WIKI"' EXIT
        git -C "$TMPDIR_WIKI" init --quiet
        git -C "$TMPDIR_WIKI" checkout -b main --quiet

        cat > "$TMPDIR_WIKI/CLAUDE.md" <<'MDEOF'
# LLM Wiki Schema

This is a Karpathy-pattern persistent knowledge base. Both local Claude Code and NanoClaw
container agents can read and write here. Sync is handled via git.

## Paths
- Local Claude Code: `~/.claude/llm-wiki/`
- NanoClaw containers: `/workspace/extra/llm-wiki/`

## Sync rules

**Before reading or editing anything:**
```bash
git -C /workspace/extra/llm-wiki pull --ff-only --quiet
```

**After any edit:**
```bash
git -C /workspace/extra/llm-wiki add -A
git -C /workspace/extra/llm-wiki commit -m "<concise summary of changes>"
git -C /workspace/extra/llm-wiki push --quiet
```

If pull fails (not fast-forwardable), stop and surface the conflict to the user.
Do not attempt to merge automatically.

## Structure

- `index.md` — catalog of all wiki pages with one-line summaries, organized by category
- `log.md` — append-only chronological record (`## [YYYY-MM-DD] operation | title`)
- `wiki/` — LLM-generated pages (summaries, entities, concepts, cross-references)
- `sources/` — raw immutable source material (articles, PDFs, images, transcripts)

## Operations

**Ingest:** User provides a source → pull → read source → discuss takeaways → create/update
wiki pages (summary, entities, concepts, cross-references) → update index.md → append log.md
→ commit + push. Process ONE source at a time. Never batch-read multiple sources and process
them together — this produces shallow pages.

**Query:** Read index.md first → drill into relevant pages → synthesize answer with citations.
Good answers can be filed back into wiki/ as new pages.

**Lint:** Check for contradictions, orphan pages (no inbound links), stale content, missing
cross-references, and gaps. Report findings and offer to fix. Run periodically or on request.

## Source download

For URLs, download the full content rather than using WebFetch (which summarizes):
```bash
# PDF / binary
curl -sLo sources/filename.pdf "<url>"
# Webpage: use agent-browser to open and extract full text
agent-browser open <url>
agent-browser snapshot
```
MDEOF

        cat > "$TMPDIR_WIKI/index.md" <<'MDEOF'
# Wiki Index

Content-oriented catalog of all wiki pages. Updated on every ingest.
Read this first before answering any query.

## Pages

_No pages yet. Add sources to begin building the wiki._
MDEOF

        cat > "$TMPDIR_WIKI/log.md" <<'MDEOF'
# Wiki Log

Append-only chronological record. Format: `## [YYYY-MM-DD] operation | title`
Parse last 5 entries: `grep "^## \[" log.md | tail -5`

---
MDEOF

        mkdir -p "$TMPDIR_WIKI/wiki" "$TMPDIR_WIKI/sources"
        touch "$TMPDIR_WIKI/wiki/.gitkeep" "$TMPDIR_WIKI/sources/.gitkeep"

        git -C "$TMPDIR_WIKI" add -A
        git -C "$TMPDIR_WIKI" -c user.name="nanoclaw" \
            -c user.email="nanoclaw@local" \
            commit -m "init: llm-wiki skeleton" --quiet
        git -C "$TMPDIR_WIKI" remote add origin "$LLM_WIKI_REMOTE"
        git -C "$TMPDIR_WIKI" push origin main --quiet
        info "LLM wiki skeleton committed and pushed to bare repo"
      fi
    fi

    if ! $DRY_RUN; then
      info "Cloning llm-wiki to $LLM_WIKI_DIR"
      git clone "$LLM_WIKI_REMOTE" "$LLM_WIKI_DIR" --quiet
      info "LLM wiki ready at $LLM_WIKI_DIR"
    else
      warn "[dry-run] Would clone $LLM_WIKI_REMOTE → $LLM_WIKI_DIR"
    fi
  fi
fi

# ── Print next steps ──────────────────────────────────────────────────────────

heading "MemPalace MCP registration (manual step)"

cat <<EOF

Add this to your ${BOLD}.mcp.json${NC} in this repo (or ~/.claude/mcp.json globally)
to give Claude Code sessions access to the shared MemPalace:

  {
    "mcpServers": {
      "mempalace": {
        "type": "sse",
        "url": "https://mempalace.home/sse"
      }
    }
  }

If your Caddy LXC uses a different hostname, replace mempalace.home accordingly.
You'll also need to trust the Caddy internal CA cert on this machine (see deploy/README.md).

EOF

heading "Add memory wiki directive to your user CLAUDE.md (manual step)"

cat <<'EOF'
Add this block to ~/.claude/CLAUDE.md so Claude Code automatically checks the wiki:

  ## Memory Wiki
  Before answering questions about Noah's projects, preferences, past decisions,
  or recurring context, read ~/.claude/memory/index.md first, then drill into
  relevant pages. If the wiki doesn't have the answer, fall back to the mempalace
  MCP tools. Propose wiki updates in chat rather than writing files directly.

EOF

info "Done!"
info "Stop hooks: sync JSONL sessions + memory wiki to VM after each session."
if $WITH_LLM_WIKI; then
  info "LLM wiki Stop hook wired — edits in ~/.claude/llm-wiki/ sync on session end."
  info "On the VM: add the llm-wiki cron from deploy/crontab.vm (pull-commit-push every 5 min)."
  info "NanoClaw side: run /add-karpathy-llm-wiki to mount the wiki RW into your agent group."
fi
info "For nightly catch-up, install the local crontab: crontab deploy/crontab.local"
info "On the VM: run 'crontab deploy/crontab.vm' to install the memory pull cron."
