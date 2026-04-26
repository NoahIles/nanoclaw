#!/bin/bash
# sync-llm-wiki.sh — Sync the llm-wiki to/from the bare repo on the VM.
# Runs as a Claude Code Stop hook after each session.
#
# Flow: pull (fast-forward, silent on conflict) → commit local changes → push.
# On first run: clones the repo if ~/.claude/llm-wiki/ doesn't exist yet.
#
# Configuration is read from ~/.config/nanoclaw/llm-wiki-sync.conf, written by
# install-stop-hook.sh (--with-llm-wiki) or by the add-karpathy-llm-wiki skill.
# LLM_WIKI_REMOTE must be set.

set -euo pipefail

CONF_FILE="${HOME}/.config/nanoclaw/llm-wiki-sync.conf"
WIKI_DIR="${HOME}/.claude/llm-wiki"
LOG_FILE="${HOME}/.local/share/nanoclaw/sync.log"

# ── Helpers ───────────────────────────────────────────────────────────────────

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] [llm-wiki-sync] $*" >> "$LOG_FILE"
}

# ── Load config ───────────────────────────────────────────────────────────────

if [[ ! -f "$CONF_FILE" ]]; then
  log "Config not found: $CONF_FILE — run scripts/install-stop-hook.sh --with-llm-wiki first"
  exit 0
fi

# shellcheck source=/dev/null
source "$CONF_FILE"

if [[ -z "${LLM_WIKI_REMOTE:-}" ]]; then
  log "LLM_WIKI_REMOTE not set in $CONF_FILE — skipping llm-wiki sync"
  exit 0
fi

mkdir -p "$(dirname "$LOG_FILE")"

# ── Clone on first run ────────────────────────────────────────────────────────

if [[ ! -d "$WIKI_DIR/.git" ]]; then
  log "Wiki repo not found — cloning from $LLM_WIKI_REMOTE"
  mkdir -p "$(dirname "$WIKI_DIR")"
  if ! git clone "$LLM_WIKI_REMOTE" "$WIKI_DIR" >> "$LOG_FILE" 2>&1; then
    log "Clone failed — skipping llm-wiki sync this session"
    exit 1
  fi
  log "Cloned to $WIKI_DIR"
fi

# ── Pull ──────────────────────────────────────────────────────────────────────

# Fast-forward only; if branches have diverged we skip the pull but still push
# local changes. The push will fail if remote is ahead, which surfaces the issue.
if ! git -C "$WIKI_DIR" pull --ff-only --quiet 2>> "$LOG_FILE"; then
  log "Pull skipped (not fast-forwardable — diverged branches?)"
fi

# ── Commit local changes ──────────────────────────────────────────────────────

if [[ -n "$(git -C "$WIKI_DIR" status --porcelain 2>/dev/null)" ]]; then
  git -C "$WIKI_DIR" add -A 2>> "$LOG_FILE"
  git -C "$WIKI_DIR" commit \
    -m "session $(date '+%Y-%m-%d %H:%M')" \
    --quiet 2>> "$LOG_FILE"
  log "Committed local wiki changes"
fi

# ── Push ──────────────────────────────────────────────────────────────────────

if git -C "$WIKI_DIR" push --quiet 2>> "$LOG_FILE"; then
  log "Wiki sync complete"
else
  log "Push failed — will retry next session"
  exit 1
fi
