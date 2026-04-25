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
#      — sync-memory.sh       (wiki git sync, async)
#   5. Bootstraps the bare memory repo on the VM + local clone (if first run)
#   6. Prints the .mcp.json entry needed for MemPalace in Claude Code
#
# Run with --dry-run to preview the settings.json merge without writing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETTINGS_FILE="${HOME}/.claude/settings.json"
CONF_DIR="${HOME}/.config/nanoclaw"
CONF_FILE="${CONF_DIR}/mempalace-sync.conf"
SYNC_SCRIPT="${REPO_ROOT}/scripts/sync-to-mempalace.sh"
MEMORY_SYNC_SCRIPT="${REPO_ROOT}/scripts/sync-memory.sh"
MEMORY_DIR="${HOME}/.claude/memory"
DRY_RUN=false

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
    --dry-run) DRY_RUN=true ;;
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
info "For nightly catch-up, install the local crontab: crontab deploy/crontab.local"
info "On the VM: run 'crontab deploy/crontab.vm' to install the memory pull cron."
