# Voxhold deploy

Production deployment for Voxhold. The deploy project runs published Docker
images; it does not require cloning the backend or frontend source code.

## Modes

The installer supports two modes:

- native-only: backend, migrations, bootstrap and Caddy;
- fullstack: the same services plus the frontend.

In native-only mode Caddy proxies HTTPS/WebSocket traffic directly to the
backend. In fullstack mode it proxies to the frontend, which serves the SPA
and forwards `/api` and WebSocket traffic to the backend.

## Install

Install Docker Engine and Docker Compose v2 on a Linux VPS, then run:

```bash
chmod +x install.sh update.sh backup.sh
./install.sh
```

The script uses the public `LoonEman1` images (lowercase in the registry path)
with the `latest` tag and asks
for the deployment mode, public host, instance name and initial owner
credentials. It writes `.env` with mode `600` and never commits it.

For a public website, use a domain whose A/AAAA record points to the VPS and
open TCP ports 80 and 443. Caddy obtains and renews the certificate. For an IP
address, Caddy's default certificate is locally trusted rather than publicly
trusted; clients must install the Caddy CA or an externally issued IP
certificate must be mounted.

Open the configured WebRTC UDP ports as well:

- `50000/udp` for voice;
- `50001/udp` for screen sharing.

Do not expose backend port 8080 or frontend port 8080 to the Internet.

## Update and backup

The installer and updater always pull the `latest` tag, then run:

```bash
./update.sh
```

Create a consistent SQLite backup with:

```bash
./backup.sh
```

The backup briefly stops the backend and leaves the Docker volumes intact.

If you are migrating an existing SQLite volume created by an older root
container, fix its ownership once before the first start:

```bash
docker volume ls | grep voxhold_data
docker run --rm --user 0 \
  -v <volume-name>:/app/data \
  alpine:3.22 \
  sh -c 'chown -R 10001:10001 /app/data && chmod 770 /app/data'
```

## Publishing images

The backend and frontend repositories should publish the `latest` tag to GHCR
for the installer, for example:

```text
ghcr.io/looneman1/voxhold-backend:latest
ghcr.io/looneman1/voxhold-frontend:latest
```

For private images, log in to GHCR on the VPS before running `install.sh`.
