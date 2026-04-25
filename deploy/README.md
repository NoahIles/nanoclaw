# Deployment Runbook

This guide walks through deploying NanoClaw + MemPalace + the memory wiki to a Proxmox VM
with Caddy on a separate LXC.

## Overview

| Host | Role |
|---|---|
| Proxmox VM | Docker Compose stack: NanoClaw, MemPalace; bare git repo for memory wiki |
| Proxmox LXC | Caddy reverse proxy |
| Local machine | Claude Code + Stop hook (pushes sessions + wiki commits to VM) |

OneCLI runs **natively on the VM** (not in Docker) as a host-level credential gateway. Docker containers reach it via `host-gateway:10254`.

---

## 1. Proxmox VM setup

### 1.1 Provision the VM

Recommended minimum specs: 2 vCPU, 4 GB RAM, 40 GB disk. Ubuntu 22.04 LTS or Debian 12.

### 1.2 Install Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

### 1.3 Install mise

```bash
curl https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc
source ~/.bashrc
```

### 1.4 Install OneCLI (runs natively on the VM host)

```bash
curl -fsSL onecli.sh/install | sh
curl -fsSL onecli.sh/cli/install | sh
export PATH="$HOME/.local/bin:$PATH"
```

Verify: `onecli version`

Start the gateway and register your Anthropic API key:

```bash
onecli start
# Wait a moment, then verify:
curl http://localhost:10254/health

# Register credentials
onecli secrets create --name Anthropic --type anthropic --host-pattern api.anthropic.com
```

The gateway auto-starts on reboot via the service it installs. Verify with `onecli status`.

### 1.5 Clone the repo

```bash
sudo mkdir -p /opt/nanoclaw
sudo chown $USER:$USER /opt/nanoclaw
git clone <your-repo-url> /opt/nanoclaw
cd /opt/nanoclaw
```

### 1.6 Configure environment

```bash
cp .env.example .env
$EDITOR .env
```

Fill in at minimum:
- `DISCORD_BOT_TOKEN`, `DISCORD_APPLICATION_ID`, `DISCORD_PUBLIC_KEY` (or whichever channels you use)
- `ASSISTANT_NAME`
- `TZ`

### 1.7 Create required directories

```bash
mkdir -p /opt/nanoclaw/{data,logs,groups,backups,imports/claude-code}
mkdir -p /opt/nanoclaw/groups/{main,global}
```

### 1.8 Create the mount allowlist

Agent containers can only bind-mount paths listed in the mount allowlist. Create it before
starting the stack so the memory wiki mount is permitted from the first session:

```bash
mkdir -p ~/.config/nanoclaw
cat > ~/.config/nanoclaw/mount-allowlist.json <<'EOF'
{
  "allowedRoots": [
    {
      "path": "/opt/nanoclaw/memory",
      "allowReadWrite": false,
      "description": "claude-memory wiki (read-only)"
    }
  ],
  "blockedPatterns": []
}
EOF
```

### 1.9 Build the agent container image

The NanoClaw agent container (used for per-session AI runs) is built separately:

```bash
./container/build.sh
```

### 1.10 Start the stack

```bash
mise run up
mise run ps   # all services should reach 'healthy' within ~60s
```

Check logs: `mise run logs`

### 1.11 Verify services

```bash
# OneCLI (native on host)
curl http://localhost:10254/health

# MemPalace MCP (internal)
docker compose exec nanoclaw curl http://mempalace:3100/healthz

# NanoClaw host logs
docker compose logs nanoclaw --tail 50
```

### 1.12 Install the VM crontab

```bash
crontab deploy/crontab.vm
crontab -l   # verify it's installed
```

Test immediately:
```bash
mise run mine
mise run backup
ls -la /opt/nanoclaw/backups/
```

---

## 2. Caddy LXC setup

### 2.1 Install Caddy

```bash
apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update && apt install caddy
```

### 2.2 Configure Caddy

```bash
cp /opt/nanoclaw/deploy/Caddyfile /etc/caddy/Caddyfile
```

Edit `/etc/caddy/Caddyfile` and replace `VM_IP` with the static LAN IP of your NanoClaw VM.

```bash
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy
```

### 2.3 Trust the internal CA on your devices

Caddy issues its own internal TLS certs. Export and trust its CA cert on each device you'll access the services from.

On the Caddy LXC:
```bash
# Find the root CA cert
ls /var/lib/caddy/.local/share/caddy/pki/authorities/local/
# Export it
cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
```

**macOS:** Double-click the cert file → Keychain Access → mark as "Always Trust"

**Linux:** `sudo cp root.crt /usr/local/share/ca-certificates/caddy-local.crt && sudo update-ca-certificates`

**Chrome/Firefox on Linux:** Import via browser certificate settings.

### 2.4 Verify

From your local machine (on LAN or VPN):

```bash
curl https://onecli.home/health
curl https://mempalace.home/healthz
```

Both should return 200 with valid TLS (no `-k` flag needed after trusting the CA).

---

## 3. Local machine setup (Claude Code Stop hook)

### 3.1 Install the Stop hook

From the NanoClaw repo on your local machine:

```bash
mise run install-hook
```

This will:
1. Prompt for your VM SSH target (e.g. `user@192.168.1.100:/opt/nanoclaw/imports/claude-code`)
2. Test SSH connectivity and create the remote directory
3. Write `~/.config/nanoclaw/mempalace-sync.conf`
4. Merge the Stop hook into `~/.claude/settings.json`

Verify the hook is wired:
```bash
cat ~/.claude/settings.json | jq '.hooks.Stop'
```

### 3.2 Install the nightly catch-up crontab

```bash
crontab deploy/crontab.local
```

Edit the path in the crontab if your repo is not at `~/Documents/toys/nanoclaw`.

### 3.3 Register MemPalace as an MCP server in Claude Code

Add to `.mcp.json` in this repo (or `~/.claude/mcp.json` for all projects):

```json
{
  "mcpServers": {
    "mempalace": {
      "type": "sse",
      "url": "https://mempalace.nislands.xyz/sse"
    }
  }
}
```

Start a new Claude Code session — MemPalace tools should appear.

---

## 4. Memory wiki setup

The memory wiki is a curated, human-readable git repo (`claude-memory`) that sits on top of
mempalace. Mempalace indexes every conversation; the wiki holds the curated highlights you
(and agents) actually navigate. It's synced as a bare git repo on the VM, cloned locally,
and mounted read-only into agent containers.

**`install-stop-hook.sh` handles most of this automatically** — it creates the bare repo,
pushes the skeleton, and clones it locally. The steps below are for reference or manual
recovery.

### 4.1 Create the bare repo on the VM (first-time only)

`install-stop-hook.sh` does this during setup. To do it manually:

```bash
# On the VM — /srv may be root-owned; chown first
sudo mkdir -p /srv/git && sudo chown $USER:$USER /srv/git
git init --bare /srv/git/claude-memory.git
```

Then push the skeleton from local (see step 4.2).

### 4.2 Clone locally

`install-stop-hook.sh` clones to `~/.claude/memory/` automatically. To clone manually:

```bash
git clone user@vm-ip:/srv/git/claude-memory.git ~/.claude/memory
```

### 4.3 Clone on the VM (for agent containers)

```bash
# On the VM
git clone /srv/git/claude-memory.git /opt/nanoclaw/memory
```

The VM crontab (`deploy/crontab.vm`) pulls this repo every 5 minutes so agents always
see recent commits.

**Clone first, then install the crontab.** If you install the cron before the clone, the
job will log "not a git repository" every 5 minutes until you clone.

```bash
# Install the crontab after cloning (includes the memory pull entry)
crontab deploy/crontab.vm
# Verify
crontab -l | grep memory
```

### 4.4 Mount the wiki into agent groups

Add an `additionalMounts` entry to each agent group's `container.json`:

```json
{
  "additionalMounts": [
    {
      "hostPath": "/opt/nanoclaw/memory",
      "containerPath": "memory",
      "readonly": true
    }
  ]
}
```

`containerPath` must be a **relative** name — the mount-security validator prefixes it with
`/workspace/extra/`. New sessions for that group will have the wiki at `/workspace/extra/memory/`.

### 4.5 Add the wiki directive to your user CLAUDE.md

So local Claude Code sessions check the wiki automatically, add this to `~/.claude/CLAUDE.md`:

```markdown
## Memory Wiki
Before answering questions about Noah's projects, preferences, past decisions, or recurring
context, read ~/.claude/memory/index.md first, then drill into relevant pages. If the wiki
doesn't have the answer, fall back to the mempalace MCP tools. Propose wiki updates in chat
rather than writing files directly.
```

NanoClaw agent containers read the same wiki at `/workspace/extra/memory/index.md` (read-only
mount). The `memory-wiki` container skill tells agents to use this path automatically.

### 4.6 Enable the memory-wiki container skill

The `memory-wiki` skill is included in `container/skills/`. Enable it for agent groups
that should use the wiki by adding it to their skill selection in `container.json`:

```json
{
  "skills": ["memory-wiki"],
  "additionalMounts": [...]
}
```

---

## 5. End-to-end validation

1. Start a Claude Code session, do some work, then `/exit`.
2. Check `~/.local/share/nanoclaw/sync.log` — should show both mempalace and memory sync entries.
3. Check `vm:/opt/nanoclaw/imports/claude-code/` — should contain your project's JSONL files.
4. Check `~/.claude/memory/` — should exist (cloned by the hook on first run).
5. Run `mise run mine` on the VM — watch logs show indexed counts.
6. Start a new Claude Code session. Ask about a project from the wiki — confirm it cites `index.md`.
7. Ask about something only in mempalace (an old transcript detail) — confirm it falls back to the MCP tool.

---

## 6. Dashboard (future)

The `dashboard.home` Caddy route is pre-commented in the Caddyfile. When ready, run the `/add-dashboard` skill, uncomment that route, and reload Caddy.

---

## Troubleshooting

**MemPalace MCP not responding:**
```bash
docker compose logs mempalace
docker compose exec mempalace curl localhost:3100/healthz
```

**Agent containers not starting:**
Verify DOOD paths — agent volume mounts must use `/opt/nanoclaw/...` (the host path):
```bash
docker inspect <agent-container-id> | jq '.[0].HostConfig.Binds'
```

**OneCLI not reachable from containers:**
```bash
docker compose exec nanoclaw curl http://host-gateway:10254/health
```
If that fails, verify OneCLI is running on the VM: `onecli status` or `curl http://localhost:10254/health`.

**Sync hook not firing:**
Check `~/.claude/settings.json` has the Stop hook, then check `~/.local/share/nanoclaw/sync.log`.
Re-run `mise run install-hook` to repair.

**Memory wiki not updating in agent containers:**
```bash
# Check VM pull cron is running
crontab -l | grep memory
# Force an immediate pull
git -C /opt/nanoclaw/memory pull --ff-only
# Check pull log
tail -20 /opt/nanoclaw/logs/memory-pull.log
```

**Memory wiki diverged (local and VM have conflicting commits):**
The fast-forward-only pull silently skips on divergence. To resolve:
```bash
# On local — see what's diverged
git -C ~/.claude/memory log --oneline origin/main..HEAD
git -C ~/.claude/memory log --oneline HEAD..origin/main
# Rebase local onto remote (preferred — keeps history linear)
git -C ~/.claude/memory pull --rebase origin main
git -C ~/.claude/memory push
```
