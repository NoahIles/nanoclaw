# Deployment Runbook

This guide walks through deploying NanoClaw + MemPalace to a Proxmox VM with Caddy on a separate LXC.

## Overview

| Host | Role |
|---|---|
| Proxmox VM | Docker Compose stack: NanoClaw, MemPalace |
| Proxmox LXC | Caddy reverse proxy |
| Local machine | Claude Code + Stop hook (pushes sessions to VM) |

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

### 1.8 Build the agent container image

The NanoClaw agent container (used for per-session AI runs) is built separately:

```bash
./container/build.sh
```

### 1.9 Start the stack

```bash
mise run up
mise run ps   # all services should reach 'healthy' within ~60s
```

Check logs: `mise run logs`

### 1.10 Verify services

```bash
# OneCLI (native on host)
curl http://localhost:10254/health

# MemPalace MCP (internal)
docker compose exec nanoclaw curl http://mempalace:3100/healthz

# NanoClaw host logs
docker compose logs nanoclaw --tail 50
```

### 1.11 Install the VM crontab

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
      "url": "https://mempalace.home/sse"
    }
  }
}
```

Start a new Claude Code session — MemPalace tools should appear.

---

## 4. End-to-end validation

1. Start a Claude Code session, do some work, then `/exit`.
2. Check `~/.local/share/nanoclaw/sync.log` — should show a successful sync.
3. Check `vm:/opt/nanoclaw/imports/claude-code/` — should contain your project's JSONL files.
4. Run `mise run mine` on the VM — watch logs show indexed counts.
5. Start a new Claude Code session with MemPalace MCP wired. Ask MemPalace to search for something from your previous session.

---

## 5. Dashboard (future)

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
