# VM Migration: memory-wiki → llm-wiki

Run this on the Proxmox VM as the user that runs NanoClaw (the same user whose `~` contains
`~/.config/nanoclaw/`). NanoClaw should be running during most steps; you'll restart it at the end.

NanoClaw is assumed to be at `/opt/nanoclaw`. Adjust if your install path differs.

---

## Step 1: Confirm current state

```bash
# Confirm memory-wiki working clone exists
ls /opt/nanoclaw/memory/.git && echo "memory clone: present" || echo "memory clone: missing"

# Confirm bare repo exists
ls /srv/git/claude-memory.git/HEAD && echo "bare repo: present" || echo "bare repo: missing"

# Confirm llm-wiki does NOT exist yet (expected)
ls /opt/nanoclaw/llm-wiki/.git 2>/dev/null && echo "llm-wiki: already exists" || echo "llm-wiki: not yet set up"
```

---

## Step 2: Bootstrap the llm-wiki bare repo and working clone

```bash
# Create the bare repo (canonical source of truth)
mkdir -p /srv/git
git init --bare /srv/git/llm-wiki.git

# Create the working clone
git clone /srv/git/llm-wiki.git /opt/nanoclaw/llm-wiki

# Push an initial skeleton commit so the clone has a main branch
TMPDIR_WIKI="$(mktemp -d)"
git -C "$TMPDIR_WIKI" init --quiet
git -C "$TMPDIR_WIKI" checkout -b main --quiet

mkdir -p "$TMPDIR_WIKI/wiki/personal" "$TMPDIR_WIKI/sources"
touch "$TMPDIR_WIKI/wiki/.gitkeep" "$TMPDIR_WIKI/sources/.gitkeep"

cat > "$TMPDIR_WIKI/index.md" <<'EOF'
# Wiki Index

Content-oriented catalog of all wiki pages. Updated on every ingest.
Read this first before answering any query.

## Personal

_Migrated from memory-wiki — see wiki/personal/_

## Pages

_No domain pages yet._
EOF

cat > "$TMPDIR_WIKI/log.md" <<'EOF'
# Wiki Log

Append-only chronological record. Format: `## [YYYY-MM-DD] operation | title`

---
EOF

git -C "$TMPDIR_WIKI" add -A
git -C "$TMPDIR_WIKI" -c user.name="nanoclaw" -c user.email="nanoclaw@local" \
    commit -m "init: llm-wiki skeleton" --quiet
git -C "$TMPDIR_WIKI" remote add origin /srv/git/llm-wiki.git
git -C "$TMPDIR_WIKI" push origin main --quiet
rm -rf "$TMPDIR_WIKI"

# Pull the skeleton into the working clone
git -C /opt/nanoclaw/llm-wiki pull --ff-only --quiet

echo "llm-wiki bootstrapped at /opt/nanoclaw/llm-wiki"
```

---

## Step 3: Migrate memory-wiki content into llm-wiki

Pull the latest memory-wiki content first, then copy it under `wiki/personal/`.

```bash
# Pull latest from remote so nothing is lost
git -C /opt/nanoclaw/memory pull --ff-only --quiet 2>/dev/null || echo "(pull skipped — may already be latest)"

# Copy everything except git metadata into wiki/personal/
rsync -av --exclude='.git' /opt/nanoclaw/memory/ /opt/nanoclaw/llm-wiki/wiki/personal/

# Commit and push the migrated content
cd /opt/nanoclaw/llm-wiki
git add -A
git commit -m "migrate: import memory-wiki content to wiki/personal/"
git push --quiet

echo "Migration committed. Review:"
ls /opt/nanoclaw/llm-wiki/wiki/personal/
```

After migration, skim the content and update `/opt/nanoclaw/llm-wiki/index.md` to catalog the
personal pages now under `wiki/personal/`. Commit the index update:

```bash
# Edit index.md to list the migrated personal pages, then:
git -C /opt/nanoclaw/llm-wiki add index.md
git -C /opt/nanoclaw/llm-wiki commit -m "index: add personal wiki pages from migration"
git -C /opt/nanoclaw/llm-wiki push --quiet
```

---

## Step 4: Update the mount allowlist

Edit `~/.config/nanoclaw/mount-allowlist.json`. Replace the memory entry with llm-wiki,
and add `allowReadWrite: true` (agents need write access):

```bash
cat > ~/.config/nanoclaw/mount-allowlist.json <<'EOF'
{
  "allowedRoots": [
    {
      "path": "/opt/nanoclaw/llm-wiki",
      "allowReadWrite": true,
      "description": "llm-wiki (Karpathy pattern, bidirectional)"
    }
  ],
  "blockedPatterns": []
}
EOF
```

If you have other entries in the allowlist (e.g., for other mounts), preserve them and only
swap out the `/opt/nanoclaw/memory` entry.

---

## Step 5: Update the group's container.json

The `dm-with-noah` group (and any other group that had the memory mount) needs its
`container.json` updated. The groups directory is at `/opt/nanoclaw/groups/`.

```bash
# Check current state
cat /opt/nanoclaw/groups/dm-with-noah/container.json
```

Replace the `additionalMounts` section to use llm-wiki with `readonly: false`, and add
the `llm-wiki` skill:

```json
{
  "mcpServers": {},
  "packages": {
    "apt": [],
    "npm": []
  },
  "skills": ["llm-wiki", "memory-wiki"],
  "additionalMounts": [
    {
      "hostPath": "/opt/nanoclaw/llm-wiki",
      "containerPath": "llm-wiki",
      "readonly": false
    }
  ]
}
```

Note: `memory-wiki` is kept in `skills` temporarily — it now contains a deprecation redirect
pointing agents at the new llm-wiki path. Remove it from the list in a future cleanup.

Write this with your editor or with `jq`:

```bash
jq '.additionalMounts = [{"hostPath":"/opt/nanoclaw/llm-wiki","containerPath":"llm-wiki","readonly":false}] | .skills = ["llm-wiki","memory-wiki"]' \
  /opt/nanoclaw/groups/dm-with-noah/container.json > /tmp/container.json.new \
  && mv /tmp/container.json.new /opt/nanoclaw/groups/dm-with-noah/container.json
```

Repeat for any other groups that previously had the `/opt/nanoclaw/memory` mount.

---

## Step 6: Update crontab

```bash
crontab -l > /tmp/crontab.current
```

In `/tmp/crontab.current`:
- **Remove or comment out** the memory pull line:
  ```
  # */5 * * * * git -C /opt/nanoclaw/memory pull --ff-only --quiet >> ...
  ```
- **Confirm** the llm-wiki line is present (it was added in `deploy/crontab.vm`):
  ```
  */5 * * * * test -d /opt/nanoclaw/llm-wiki/.git && cd /opt/nanoclaw/llm-wiki && ...
  ```
  If it's missing, add it now (copy from `deploy/crontab.vm` in the repo).

```bash
crontab /tmp/crontab.current
crontab -l  # verify
```

---

## Step 7: Rebuild and restart

The `llm-wiki` container skill was added to the repo after the current image was built.
Rebuild to include it:

```bash
cd /opt/nanoclaw
./container/build.sh
systemctl --user restart nanoclaw
```

Wait ~10 seconds, then confirm NanoClaw is healthy:

```bash
systemctl --user status nanoclaw
tail -20 /opt/nanoclaw/logs/nanoclaw.log
```

---

## Step 8: Smoke test

Send a message to the `dm-with-noah` agent group. The agent should:
1. Start without errors
2. See `/workspace/extra/llm-wiki/` as a writable mount
3. Load the `llm-wiki` and `memory-wiki` skills
4. Be able to run `git pull` and `git push` inside the wiki dir

Quick test prompt to send:
> "Check the llm-wiki: pull latest, show me index.md, and confirm you can write to it."

---

## Step 9: Archive old memory-wiki infrastructure (optional, do after confirming all works)

The working clone can be removed once the llm-wiki is confirmed healthy. Keep the bare repo
for a while as a backup.

```bash
# Remove working clone (data is now in llm-wiki)
rm -rf /opt/nanoclaw/memory

# Optionally archive the bare repo instead of deleting immediately
mv /srv/git/claude-memory.git /srv/git/claude-memory.git.bak
# Delete once you're confident nothing references it:
# rm -rf /srv/git/claude-memory.git.bak
```

---

## Local laptop side (do separately in your Claude Code session)

These are not VM tasks but should be cleaned up at some point:

- Remove the `sync-memory.sh` Stop hook from `~/.claude/settings.json`
- Migrate `~/.claude/memory/` content to `~/.claude/llm-wiki/wiki/personal/`
- Remove `MEMORY_GIT_REMOTE` from `~/.config/nanoclaw/mempalace-sync.conf` (or leave it — the sync script exits cleanly if the conf key is missing)
- Bootstrap `~/.claude/llm-wiki/` by cloning from the VM bare repo (or run `install-stop-hook.sh --with-llm-wiki`)
