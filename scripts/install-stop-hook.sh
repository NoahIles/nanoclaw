#!/bin/bash
# install-stop-hook.sh — Wire the Claude Code Stop hook for MemPalace sync.
#
# What this does:
#   1. Prompts for the VM SSH target (user@host:/opt/nanoclaw/imports/claude-code)
#   2. Tests SSH + rsync connectivity
#   3. Writes ~/.config/nanoclaw/mempalace-sync.conf
#   4. Merges the Stop hook entry into ~/.claude/settings.json (idempotent)
#   5. Prints the .mcp.json entry needed for MemPalace in Claude Code
#
# Run with --dry-run to preview the settings.json merge without writing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETTINGS_FILE="${HOME}/.claude/settings.json"
CONF_DIR="${HOME}/.config/nanoclaw"
CONF_FILE="${CONF_DIR}/mempalace-sync.conf"
SYNC_SCRIPT="${REPO_ROOT}/scripts/sync-to-mempalace.sh"
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
if [[ -f "$CONF_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONF_FILE"
  existing_target="${MEMPALACE_SSH_TARGET:-}"
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

if $DRY_RUN; then
  warn "[dry-run] Would write to $CONF_FILE:"
  echo "  MEMPALACE_SSH_TARGET=${SSH_TARGET}"
else
  mkdir -p "$CONF_DIR"
  chmod 700 "$CONF_DIR"
  cat > "$CONF_FILE" <<EOF
# Written by install-stop-hook.sh — edit with care
MEMPALACE_SSH_TARGET=${SSH_TARGET}
EOF
  chmod 600 "$CONF_FILE"
  info "Config written to $CONF_FILE"
fi

# ── Merge Stop hook into settings.json ───────────────────────────────────────

heading "Wiring Claude Code Stop hook"

HOOK_ENTRY=$(jq -n \
  --arg cmd "$SYNC_SCRIPT" \
  '[{"matcher": "", "hooks": [{"type": "command", "command": $cmd, "timeout": 15, "async": true}]}]')

# Read existing settings or start with empty object
if [[ -f "$SETTINGS_FILE" ]]; then
  existing=$(cat "$SETTINGS_FILE")
else
  existing="{}"
fi

# Idempotent merge: if Stop hook pointing to this script already exists, skip
already_wired=$(echo "$existing" | jq --arg cmd "$SYNC_SCRIPT" \
  '.hooks.Stop // [] | map(.hooks // [] | map(.command == $cmd)) | flatten | any')

if [[ "$already_wired" == "true" ]]; then
  info "Stop hook already wired — no changes needed"
else
  merged=$(echo "$existing" | jq \
    --argjson hook "$HOOK_ENTRY" \
    '.hooks.Stop = ((.hooks.Stop // []) + $hook)')

  if $DRY_RUN; then
    warn "[dry-run] Would merge into $SETTINGS_FILE:"
    echo "$merged" | jq '.hooks.Stop'
  else
    echo "$merged" > "$SETTINGS_FILE"
    info "Stop hook added to $SETTINGS_FILE"
  fi
fi

# ── Print MCP config hint ─────────────────────────────────────────────────────

heading "MemPalace MCP registration (manual step)"

MEMPALACE_HOST="${SSH_HOST#*@}"
cat <<EOF

Add this to your ${BOLD}.mcp.json${NC} in this repo (or ~/.claude/mcp.json globally)
to give Claude Code sessions access to the shared MemPalace palace:

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

info "Done! The Stop hook will sync your Claude Code sessions to the VM after each session."
info "For nightly catch-up, install the local crontab: crontab deploy/crontab.local"
