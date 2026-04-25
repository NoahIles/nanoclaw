#!/bin/bash
# sync-memory.sh — Sync the claude-memory wiki to/from the bare repo on the VM.
# Runs as a Claude Code Stop hook after each session.
#
# Flow: pull (fast-forward, silent on conflict) → commit local changes → push.
# On first run: clones the repo if ~/.claude/memory/ doesn't exist yet.
#
# Configuration is read from ~/.config/nanoclaw/mempalace-sync.conf, written by
# install-stop-hook.sh. MEMORY_GIT_REMOTE must be set.

set -euo pipefail

CONF_FILE="${HOME}/.config/nanoclaw/mempalace-sync.conf"
MEMORY_DIR="${HOME}/.claude/memory"
LOG_FILE="${HOME}/.local/share/nanoclaw/sync.log"

# ── Helpers ───────────────────────────────────────────────────────────────────

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] [memory-sync] $*" >> "$LOG_FILE"
}

# ── Load config ───────────────────────────────────────────────────────────────

if [[ ! -f "$CONF_FILE" ]]; then
  log "Config not found: $CONF_FILE — run scripts/install-stop-hook.sh first"
  exit 0
fi

# shellcheck source=/dev/null
source "$CONF_FILE"

if [[ -z "${MEMORY_GIT_REMOTE:-}" ]]; then
  log "MEMORY_GIT_REMOTE not set in $CONF_FILE — skipping memory sync"
  exit 0
fi

mkdir -p "$(dirname "$LOG_FILE")"

# ── Clone on first run ────────────────────────────────────────────────────────

if [[ ! -d "$MEMORY_DIR/.git" ]]; then
  log "Memory repo not found — cloning from $MEMORY_GIT_REMOTE"
  mkdir -p "$(dirname "$MEMORY_DIR")"
  if ! git clone "$MEMORY_GIT_REMOTE" "$MEMORY_DIR" >> "$LOG_FILE" 2>&1; then
    log "Clone failed — skipping memory sync this session"
    exit 1
  fi
  log "Cloned to $MEMORY_DIR"
fi

# ── Pull ──────────────────────────────────────────────────────────────────────

# Fast-forward only; if branches have diverged we skip the pull but still push
# local changes. The push will fail if remote is ahead, which surfaces the issue.
if ! git -C "$MEMORY_DIR" pull --ff-only --quiet 2>> "$LOG_FILE"; then
  log "Pull skipped (not fast-forwardable — diverged branches?)"
fi

# ── Commit local changes ──────────────────────────────────────────────────────

if [[ -n "$(git -C "$MEMORY_DIR" status --porcelain 2>/dev/null)" ]]; then
  git -C "$MEMORY_DIR" add -A 2>> "$LOG_FILE"
  git -C "$MEMORY_DIR" commit \
    -m "session $(date '+%Y-%m-%d %H:%M')" \
    --quiet 2>> "$LOG_FILE"
  log "Committed local memory changes"
fi

# ── Push ──────────────────────────────────────────────────────────────────────

if git -C "$MEMORY_DIR" push --quiet 2>> "$LOG_FILE"; then
  log "Memory sync complete"
else
  log "Push failed — will retry next session"
  exit 1
fi
