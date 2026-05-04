# Operations Runbook

Day-2 operational tasks for the production deployment.

---

## DigitalOcean Droplet provisioning (one-time)

We deploy on a single DO droplet running `docker compose`, with **Caddy** as
a TLS-terminating reverse proxy. Recommended size: **4 GB / 2 vCPU**
(~$24/month). Anything smaller will OOM during the OpenAI calls.

### 1. Provision

- DO control panel → Droplets → Create
- Image: Ubuntu 24.04 LTS
- Plan: Basic / 4 GB / 2 vCPU / 80 GB SSD
- Region: NYC3 or SFO3 (close to OpenAI)
- Authentication: SSH key (no passwords)
- Hostname: `msc-prod-1`
- Optional: enable backups ($1.20/month)

### 2. Initial setup (as root)

```bash
ssh root@<droplet-ip>

# Create non-root user
adduser deploy
usermod -aG sudo deploy
rsync --archive --chown=deploy:deploy ~/.ssh /home/deploy
exit
```

### 3. Install Docker (as deploy)

```bash
ssh deploy@<droplet-ip>

curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker deploy
# log out, log back in
```

### 4. Clone + first deploy

```bash
ssh deploy@<droplet-ip>
git clone https://github.com/yw2877/5381-APP-Tool.git
cd 5381-APP-Tool
cp .env.example .env
# Then edit .env: set OPENAI_API_KEY=<your-openai-api-key> and replace
# TV_WEBHOOK_SECRET with a freshly generated secret, e.g.:
# sed -i "s|^TV_WEBHOOK_SECRET=.*|TV_WEBHOOK_SECRET=$(openssl rand -hex 16)|" .env
docker compose up -d
docker compose logs -f shiny  # verify "Listening on 0.0.0.0:3838"
```

### 5. Caddy reverse proxy (TLS)

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install caddy
```

`/etc/caddy/Caddyfile` (replace `msc.example.com` and `webhook.example.com`
with your **actual** domains — these are illustrative only):

```
msc.example.com {
    reverse_proxy localhost:3838
}

webhook.example.com {
    reverse_proxy localhost:8000
}
```

```bash
sudo systemctl reload caddy
```

Caddy auto-issues Let's Encrypt certificates.

### 6. Point DNS

In your DNS provider, point your **real** domains at the droplet
(`msc.example.com` / `webhook.example.com` below are illustrative — use
yours):

- `<your-app-domain>`     → A record → droplet IP
- `<your-webhook-domain>` → A record → droplet IP

### 7. Smoke test

```bash
curl -s https://<your-app-domain>/                 # 200 OK
curl -s https://<your-webhook-domain>/health | jq  # ok = true
```

---

## Auto-deploy from GitHub `main`

We use a tiny git-pull cron + docker compose restart on the droplet:

```bash
# As deploy user, install crontab entry
crontab -e

# add:
*/5 * * * * cd /home/deploy/5381-APP-Tool && git pull --quiet && docker compose up -d --build > /dev/null 2>&1
```

Every 5 minutes the droplet pulls main and rebuilds if anything changed.
docker compose's `restart: unless-stopped` keeps services up between checks.

For a more robust setup, switch to GitHub Actions + SSH deploy.

---

## Backup

SQLite holds all alerts + agent_runs + quality_scores. Lose this and the
Quality Dashboard goes blank.

```bash
# Daily 3am backup, keep 14 days
crontab -e

# add:
0 3 * * * /home/deploy/5381-APP-Tool/scripts/backup.sh
```

`scripts/backup.sh`:

```bash
#!/bin/bash
set -euo pipefail
BACKUP_DIR=/home/deploy/backups
mkdir -p "$BACKUP_DIR"
DATE=$(date +%F)
docker exec msc-shiny sqlite3 /app/data/alerts.sqlite ".backup '/app/data/alerts-$DATE.sqlite'"
docker cp msc-shiny:/app/data/alerts-$DATE.sqlite "$BACKUP_DIR/"
docker exec msc-shiny rm /app/data/alerts-$DATE.sqlite

# Prune backups older than 14 days
find "$BACKUP_DIR" -name "alerts-*.sqlite" -mtime +14 -delete
```

Restore:

```bash
docker compose down
docker run --rm -v 5381-app-tool_sqlite-data:/data -v $PWD:/host \
  alpine sh -c "cp /host/alerts-2026-04-15.sqlite /data/alerts.sqlite"
docker compose up -d
```

---

## Rotate `OPENAI_API_KEY`

```bash
ssh deploy@<droplet-ip>
cd 5381-APP-Tool
nano .env                          # update OPENAI_API_KEY=<your-new-openai-api-key>
docker compose up -d                # picks up new env
docker compose logs -f shiny | grep openai
```

The prompt-hash cache survives a restart; no warmup needed.

---

## Reading logs

```bash
docker compose logs -f shiny           # last 100 lines, follow
docker compose logs --since 1h shiny   # last hour
docker compose logs webhook | grep ERROR
```

For richer queries:

```bash
docker compose logs --no-color shiny > shiny.log
grep '\[record_agent_run\]' shiny.log | wc -l   # rows written
```

---

## Monitoring alerts

In the DigitalOcean console:

- Droplets → msc-prod-1 → **Alerts**
- Add: CPU > 80% for 10 min  → email
- Add: Memory > 85% for 10 min → email
- Add: Disk > 75%  → email (SQLite grows)
- Add: Outbound bandwidth > 1 GB/h → email (runaway loop?)

---

## Common operations

### Restart cleanly without data loss

```bash
docker compose restart
# or selectively:
docker compose restart shiny
```

### Force full rebuild

```bash
docker compose build --no-cache
docker compose up -d --force-recreate
```

### Reset SQLite (DESTRUCTIVE — wipes alerts)

```bash
docker compose down
docker volume rm 5381-app-tool_sqlite-data
docker compose up -d
```

### Tail Plumber webhook responses

```bash
docker compose logs -f webhook
# In another shell:
curl -X POST http://localhost:8000/tv-alert \
  -H 'Content-Type: application/json' \
  -H "X-TV-SECRET: $(grep TV_WEBHOOK_SECRET .env | cut -d= -f2)" \
  -d '{"symbol":"SPY","event_type":"bollinger_breakdown","message":"test"}'
```

You should see a `202 Accepted` immediately, then ~10 seconds later in the
Shiny tab a new row appears in Alert Log & Ops.

---

## SLOs (target)

| SLO | Target | How to check |
|---|---|---|
| Webhook acknowledgement | p95 < 500 ms | `/metrics` endpoint, `p95_latency_ms` (per-call) — webhook returns 202 immediately |
| End-to-end pipeline (alert → memo) | p95 < 15 s | Quality Dashboard p95 latency KPI |
| Quality pass rate | > 80% | Quality Dashboard "Pass Rate" KPI |
| Error rate | < 5% | Quality Dashboard "Error Rate" KPI; auto-flagged at 5% |
| Yahoo cache hit (warm) | > 70% | System Status card (Ops page) |
