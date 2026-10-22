# FreePBX + Asterisk Docker Installer

Open-source installer for **FreePBX 17** and **Asterisk 21** on Linux using Docker Compose.

**Production** pulls a prebuilt image from GitHub Container Registry (`ghcr.io/astrum-studio/asterisk-docker`).  
**Development** builds locally from the `Dockerfile` (Debian 12 + Asterisk compile, 20–40 min first time).

`network_mode: host` is used for the PBX container so SIP/RTP work reliably on a VM or bare metal without Docker NAT rewriting media addresses.

## Requirements

- Linux with Docker Engine, Docker Compose v2, and OpenSSL
- Enough disk space for image build (~5 GB) and runtime data
- Ports available on the host: `HTTP_PORT` (default `8080`), SIP `5060`, RTP `10000-20000`

## Quick install

**One-liner** (клонирует в `/opt/asterisk-docker`, ставит Docker при необходимости):

```bash
curl -fsSL https://raw.githubusercontent.com/Astrum-Studio/asterisk-docker/main/scripts/autoinstaller.sh | sudo bash -s -- --yes
```

**Из git-клона:**

```bash
git clone https://github.com/Astrum-Studio/asterisk-docker.git
cd asterisk-docker

chmod +x install.sh scripts/autoinstaller.sh
./install.sh --yes
```

Перед изменениями на хосте `install.sh` проверяет ОС, свободное место и занятость портов (HTTP, MariaDB, SIP `5060`/`5061`, AMI, RTP).

`install.sh` will:

1. Copy `.env.example` → `.env` if `.env` does not exist and generate random secrets for placeholder passwords
2. Create runtime directories (`data/`, `www/`, `mysql/`, `asterisk/`, …)
3. **Pull** the FreePBX image from GHCR (production) or **build** locally with `--dev`
4. Start `db` and `freepbx`

Pin a release tag:

```bash
export FREEPBX_IMAGE_TAG=1.2.3
./install.sh --yes
```

Local development build:

```bash
./install.sh --dev
```

After the first start, open:

```text
http://<server-ip>:8080/admin
```

First `./install.sh --dev` build can take **20–40 minutes** (Asterisk is compiled from source). Production `./install.sh` only pulls the GHCR image.

## Docker images

```
ghcr.io/astrum-studio/asterisk-docker:latest
ghcr.io/astrum-studio/asterisk-docker:sha-<commit>
```

Published on push to `main` and on git tags `v*`. See `.github/workflows/publish-image.yml`.

## Manual setup

**Production (GHCR):**

```bash
cp .env.example .env
export FREEPBX_IMAGE_TAG=latest
mkdir -p data www mysql asterisk sounds/custom recordings voicemail certs logs
docker compose pull
docker compose up -d
```

**Development (local build):**

```bash
cp .env.example .env
mkdir -p data www mysql asterisk sounds/custom recordings voicemail certs logs
docker compose -f docker-compose.dev.yml build
docker compose -f docker-compose.dev.yml up -d
docker compose -f docker-compose.dev.yml logs -f freepbx
```

MariaDB is published on `${FREEPBX_DB_BIND}:${FREEPBX_DB_PORT}` (default `127.0.0.1:3307`). The `freepbx` container uses `127.0.0.1` because it runs with host networking. Restrict `${FREEPBX_DB_PORT}` with a firewall if you bind it beyond localhost.

## Asterisk AMI

AMI is enabled during container startup from `.env`. Credentials and ACLs are written to `asterisk/manager_custom.conf` (included by FreePBX) and re-applied after every `fwconsole reload`.

AMI listens on `ASTERISK_AMI_BINDADDR:ASTERISK_AMI_PORT` (default `0.0.0.0:5038` in `.env.example`) and permits loopback. When `ASTERISK_AMI_PERMIT_HOST_IPS=1`, host interface IPs are added. When `ASTERISK_AMI_PERMIT_DOCKER=1` (default), `docker0` and `br-*` bridge subnets on the host are permitted, so another container on the same machine can reach AMI without a hardcoded bridge address.

Restrict TCP `5038` with a firewall. For a client in another Compose project on the same host, point it at `host.docker.internal` (`extra_hosts: host.docker.internal:host-gateway`).

The installer generates `ASTERISK_AMI_PASSWORD` when it creates `.env`, or when the existing `.env` still contains the placeholder value.

For local AMI access from the host:

```bash
set -a && source .env && set +a
docker compose exec freepbx asterisk -rx "manager show users"
```

If remote AMI access is required, add CIDRs via `ASTERISK_AMI_PERMIT_EXTRA`, keep `ASTERISK_AMI_BINDADDR=0.0.0.0`, and restrict TCP `5038` with a firewall before restarting `freepbx`.

## Project layout

| Path | In git | Purpose |
|------|--------|---------|
| `Dockerfile` | yes | Debian 12 + Asterisk 21 + FreePBX 17 tarball |
| `docker-compose.yml` | yes | Production: `db` + GHCR `freepbx` |
| `docker-compose.dev.yml` | yes | Development: local `build` |
| `docker/` | yes | entrypoint, nginx, supervisor, DB init |
| `.env.example` | yes | Environment template |
| `install.sh` | yes | One-command installer |
| `scripts/autoinstaller.sh` | yes | curl \| bash entrypoint (clone to `/opt/asterisk-docker`) |
| `data/`, `www/`, `mysql/`, `asterisk/` | no | Created on first run; hold PBX state |
| `recordings/`, `voicemail/`, `certs/`, `logs/` | no | Runtime data |

## Firewall (UFW example)

Replace `LAN_CIDR` with your subnet:

```bash
LAN_CIDR="192.168.1.0/24"

sudo ufw allow OpenSSH
sudo ufw allow from "$LAN_CIDR" to any port 8080 proto tcp comment 'FreePBX HTTP'
sudo ufw allow from "$LAN_CIDR" to any port 5060 proto udp comment 'SIP UDP'
sudo ufw allow from "$LAN_CIDR" to any port 5060 proto tcp comment 'SIP TCP'
sudo ufw allow from "$LAN_CIDR" to any port 10000:20000 proto udp comment 'RTP audio'
sudo ufw enable
```

## fail2ban (SIP brute-force protection)

FreePBX uses host networking, so fail2ban runs on the **host** and reads Asterisk logs from `./logs/asterisk/full`.

```bash
sudo chmod +x docker/fail2ban/install.sh
sudo docker/fail2ban/install.sh
```

Defaults: ban after **5** failed REGISTER/INVITE auth attempts in **10 minutes** for **24 hours** on SIP ports `5060/5061` (TCP+UDP).

Trusted office/VPN/SIP-trunk subnets (never banned):

```bash
# in .env
FAIL2BAN_IGNORE_IP=127.0.0.1/8,::1,192.168.1.0/24
sudo docker/fail2ban/install.sh
```

Check status:

```bash
fail2ban-client status asterisk-freepbx
```

The installer also adds logrotate for `logs/asterisk/full` (daily, max 100M per file, keep 7 rotations).

## FreePBX settings to verify

In the web UI:

- **Settings → Asterisk SIP Settings → RTP Port Ranges**: `10000-20000` (match `.env`)
- **Settings → Asterisk SIP Settings → Local Networks**: your LAN CIDR
- **Settings → Asterisk SIP Settings → External Address**: VM/public IP if behind NAT

## Operations

```bash
docker compose ps
docker compose logs -f freepbx
docker compose restart freepbx
docker compose exec freepbx bash
docker compose exec freepbx asterisk -rvvv
```

After pulling script changes in **dev** mode, rebuild the image:

```bash
docker compose -f docker-compose.dev.yml build freepbx
docker compose -f docker-compose.dev.yml up -d freepbx
```

Production hosts pull a new tag instead:

```bash
export FREEPBX_IMAGE_TAG=latest
docker compose pull freepbx && docker compose up -d freepbx
```

### Inbound calls fail or extensions do not ring

FreePBX keeps extension/device mappings in Asterisk **astdb** (separate from MariaDB). In Docker this tree was not always rebuilt after `fwconsole reload`, so calls could reach the PBX but fail before `Dial(PJSIP/...)`.

On every container start, `freepbx-post-start` now:

1. Creates `/var/lib/asterisk/{bin,agi-bin}` symlinks expected by FreePBX
2. Runs `fwconsole reload`
3. Runs `fwconsole util resetastdb` to rebuild `AMPUSER`/`DEVICE` from MariaDB
4. Normalizes inbound-route `cidnum` NULL values (PHP 8.2 compatibility)

Manual repair on a running container:

```bash
docker compose exec freepbx /usr/local/bin/freepbx-ensure-layout
docker compose exec freepbx fwconsole reload
docker compose exec freepbx /usr/local/bin/freepbx-sync-runtime
docker compose exec freepbx asterisk -rx "database show AMPUSER"
```

### FreePBX shows "Cannot connect to Asterisk"

This usually means FreePBX's internal AMI user in MariaDB no longer matches `asterisk/manager.conf` (for example after a partial reset or restore). On container start, `freepbx-post-start` now syncs those credentials before `fwconsole reload`.

To repair a running container manually:

```bash
docker compose exec freepbx bash -lc 'source /usr/local/bin/freepbx-ensure-ami; sync_freepbx_manager_user; reload_asterisk_ami; fwconsole reload'
```

Check AMI users:

```bash
docker compose exec freepbx asterisk -rx "manager show users"
```

Database shell:

```bash
set -a && source .env && set +a
docker compose exec db mariadb -u"$FREEPBX_DB_USER" -p"$FREEPBX_DB_PASS" "$FREEPBX_DB_NAME"
```

### Reset after a failed first install

```bash
docker compose down
sudo rm -rf mysql/* asterisk/* www/* data/*
./install.sh
```

### Backup

```bash
set -a && source .env && set +a

docker compose exec db mariadb-dump \
  -uroot -p"$MYSQL_ROOT_PASSWORD" \
  --databases "$FREEPBX_DB_NAME" "$FREEPBX_CDR_DB_NAME" \
  | gzip > freepbx-db-$(date +%F).sql.gz
```

Stop containers before archiving runtime directories (`data/`, `www/`, `mysql/`, `asterisk/`, etc.).

## Notes

- No `ports:` section on `freepbx` — host networking binds SIP/RTP/HTTP directly on the host.
- Change `HTTP_PORT` or `FREEPBX_DB_PORT` in `.env` if defaults conflict with other services.
- HTTP only inside the stack; put TLS on a reverse proxy for production.
- FreePBX and Asterisk are GPL-licensed upstream projects; this repository only provides the Docker installer wrapper (MIT).

## License

MIT — see [LICENSE](LICENSE).
