# Voxhold deploy

Production deployment for Voxhold. This repository runs published container
images and does not require backend or frontend source code on the server.

## Deployment modes

The installer supports:

- backend-only for native or independently hosted clients;
- backend with the official Voxhold website;
- backend with any compatible third-party frontend image.

Caddy owns the public HTTP/HTTPS ports. Requests under `/api/*`, including the
`/api/v1/ws` WebSocket endpoint, always go directly to the Voxhold backend.
All other requests go to the selected frontend in web mode. A custom frontend
therefore does not need to bundle an API reverse proxy.

## Install

Install Docker Engine, Docker Compose v2 and Git on a Linux VPS, then clone this
repository:

```bash
git clone https://github.com/LoonEman1/voxhold-deploy.git
cd voxhold-deploy
chmod +x install.sh update.sh backup.sh
./install.sh
```

The installer asks for complete backend and frontend image references. Defaults
use the official public images:

```text
ghcr.io/looneman1/voxhold-backend:latest
ghcr.io/looneman1/voxhold-frontend:latest
```

It writes a private `.env` file with mode `600`; that file is excluded from Git.
For reproducible production updates, prefer a release tag or an immutable image
digest instead of `latest`.

For a public website, use a domain whose A/AAAA record points to the VPS and
open TCP ports 80 and 443. Caddy obtains and renews the certificate. Also open:

- `50000/udp` for voice;
- `50001/udp` for screen sharing.

Backend and frontend HTTP ports are only available inside the Compose network.

## Using a custom frontend

Choose web mode in `install.sh`, enter the third-party image reference and the
port that image listens on. The same values can be changed later in `.env`:

```dotenv
VOXHOLD_FRONTEND_IMAGE=ghcr.io/example/custom-voxhold-ui:v1.2.0
VOXHOLD_FRONTEND_PORT=8080
EDGE_UPSTREAM=frontend:8080
```

A compatible frontend image must:

- serve its website over HTTP on the configured internal port;
- call the Voxhold API with same-origin `/api/v1/...` URLs;
- connect WebSocket clients to same-origin `/api/v1/ws`;
- contain all required runtime assets and configuration.

The image does not need to expose a host port or proxy requests to the backend.
Only run images that you trust. A private registry image requires `docker login`
on the server before installation or update.

## Independent image versions

Backend and frontend references are independent. Both tags and digests work:

```dotenv
VOXHOLD_BACKEND_IMAGE=ghcr.io/looneman1/voxhold-backend:sha-<commit>
VOXHOLD_FRONTEND_IMAGE=ghcr.io/example/custom-voxhold-ui@sha256:<digest>
```

The migration and bootstrap jobs always use exactly the same image as the
backend service.

## Update and backup

Pull and restart the configured mode:

```bash
./update.sh
```

Create a consistent SQLite backup:

```bash
./backup.sh
```

The backup briefly stops the backend and leaves the Docker volumes intact.

If an existing SQLite volume was created by an older root container, fix its
ownership once before the first start:

```bash
docker volume ls | grep voxhold_data
docker run --rm --user 0 \
  -v <volume-name>:/app/data \
  alpine:3.22 \
  sh -c 'chown -R 10001:10001 /app/data && chmod 770 /app/data'
```
