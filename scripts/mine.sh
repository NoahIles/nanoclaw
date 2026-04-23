#!/bin/bash
# mine.sh — Trigger the MemPalace miner via Docker Compose.
# Used by VM cron and by: mise run mine
#
# Run from the nanoclaw repo root on the VM.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [mine] $*"; }

log "Starting MemPalace mining run"
cd "$REPO_ROOT"
docker compose run --rm mempalace-miner
log "Mining run complete"
