#!/bin/bash
# sync-to-mempalace.sh — Push Claude Code conversation history to the NanoClaw VM.
# Run by the Claude Code Stop hook after each session ends, and by nightly cron
# on the local machine as a catch-up for any sessions the hook missed.
#
# Configuration is read from ~/.config/nanoclaw/mempalace-sync.conf, written by
# install-stop-hook.sh. Run that script first to set up the SSH target.

set -euo pipefail

CONF_FILE="${HOME}/.config/nanoclaw/mempalace-sync.conf"
CLAUDE_PROJECTS_DIR="${HOME}/.claude/projects"
LOG_FILE="${HOME}/.local/share/nanoclaw/sync.log"

# ── Helpers ───────────────────────────────────────────────────────────────────

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] [sync] $*" >> "$LOG_FILE"
}

die() {
  log "ERROR: $*"
  exit 1
}

# ── Load config ───────────────────────────────────────────────────────────────

if [[ ! -f "$CONF_FILE" ]]; then
  die "Config not found: $CONF_FILE — run scripts/install-stop-hook.sh first"
fi

# shellcheck source=/dev/null
source "$CONF_FILE"

# MEMPALACE_SSH_TARGET must be set by the conf file, e.g.:
#   MEMPALACE_SSH_TARGET=user@192.168.1.100:/opt/nanoclaw/imports/claude-code

if [[ -z "${MEMPALACE_SSH_TARGET:-}" ]]; then
  die "MEMPALACE_SSH_TARGET not set in $CONF_FILE"
fi

# ── Sync ──────────────────────────────────────────────────────────────────────

mkdir -p "$(dirname "$LOG_FILE")"

if [[ ! -d "$CLAUDE_PROJECTS_DIR" ]]; then
  log "Claude projects dir not found: $CLAUDE_PROJECTS_DIR — skipping"
  exit 0
fi

log "Syncing $CLAUDE_PROJECTS_DIR → $MEMPALACE_SSH_TARGET"

if rsync -az --delete \
    --include="**/*.jsonl" \
    --exclude="*" \
    --timeout=15 \
    "$CLAUDE_PROJECTS_DIR/" \
    "$MEMPALACE_SSH_TARGET/" \
    2>> "$LOG_FILE"; then
  log "Sync complete"
else
  log "Sync failed (exit $?) — will be retried by nightly cron"
  exit 1
fi
