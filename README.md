English | [Русский](README.ru.md)

# Voxhold deploy

Production deployment files for Voxhold. This repository runs published
container images; backend and frontend source code are not required on the
server.

## Supported platform

The deployment scripts support **Linux servers only** (`linux/amd64` and
`linux/arm64`). Docker Desktop on Windows and macOS is not a supported
production target. Voxhold clients can still run on any platform supported by
the individual client.

Required software:

- Docker Engine;
- Docker Compose v2;
- `curl` and `tar` for bootstrap installation.

## One-command installation without Git

From the directory that should contain Voxhold, run:

```bash
curl -fsSL https://raw.githubusercontent.com/LoonEman1/voxhold-deploy/main/bootstrap.sh | bash
```

The bootstrap downloads a repository snapshot into `./voxhold-deploy`, checks
the required files and opens the interactive installer. Git is not used. The
target directory must not already exist.

To install into another directory:

```bash
curl -fsSL https://raw.githubusercontent.com/LoonEman1/voxhold-deploy/main/bootstrap.sh \
  | VOXHOLD_DEPLOY_DIR="$HOME/voxhold-server" bash
```

After publishing a release tag, use it instead of `main` in both locations for
reproducible production installations. For example, for `v1.0.0`:

```bash
curl -fsSL https://raw.githubusercontent.com/LoonEman1/voxhold-deploy/v1.0.0/bootstrap.sh \
  | VOXHOLD_DEPLOY_REF=v1.0.0 bash
```

Piping a remote script into Bash should only be done from a repository you
trust. To inspect it first:

```bash
curl -fsSLo bootstrap.sh \
  https://raw.githubusercontent.com/LoonEman1/voxhold-deploy/main/bootstrap.sh
less bootstrap.sh
bash bootstrap.sh
```

## Deployment modes

The installer supports:

- backend-only for native or independently hosted clients;
- backend with the official Voxhold website;
- backend with any compatible third-party frontend image.

At startup, select English or Russian. The installer then asks for the mode,
container images, public host, initial owner account and whether Voxhold should
start automatically after a server reboot.

The recommended autostart option applies the `unless-stopped` restart policy to
backend, frontend and Caddy, and attempts to enable the Docker systemd service.
Answering no applies `restart: no`; the stack starts during installation but
must be started manually after a reboot.

## Networking

Caddy owns public HTTP/HTTPS ports. Requests under `/api/*`, including the
`/api/v1/ws` WebSocket endpoint, always go directly to the backend. Other
requests go to the selected frontend in web mode.

For a public website, point the domain's A/AAAA record to the server and allow:

- `80/tcp` and `443/tcp` for HTTP/HTTPS;
- `50000/udp` for voice;
- `50001/udp` for screen sharing.

Backend and frontend HTTP ports are available only inside the Compose network.
Caddy obtains and renews a public certificate when a domain is used. An IP
address uses Caddy's locally trusted certificate unless an external IP
certificate is configured.

## Container images

The defaults are:

```text
ghcr.io/looneman1/voxhold-backend:latest
ghcr.io/looneman1/voxhold-frontend:latest
```

Backend and frontend references are independent and accept both tags and
digests:

```dotenv
VOXHOLD_BACKEND_IMAGE=ghcr.io/looneman1/voxhold-backend:sha-<commit>
VOXHOLD_FRONTEND_IMAGE=ghcr.io/example/custom-voxhold-ui@sha256:<digest>
```

For reproducible updates, prefer a release tag or immutable digest instead of
`latest`. Private images require `docker login` before installation or update.
Migration and bootstrap jobs always use exactly the same image reference as the
backend service.

## Custom frontend contract

Choose web mode, then enter the image and its internal HTTP port. These values
can be changed later in `.env`:

```dotenv
VOXHOLD_FRONTEND_IMAGE=ghcr.io/example/custom-voxhold-ui:v1.2.0
VOXHOLD_FRONTEND_PORT=8080
EDGE_UPSTREAM=frontend:8080
```

A compatible frontend must:

- serve HTTP on the configured internal port;
- call the API using same-origin `/api/v1/...` URLs;
- connect WebSocket clients to same-origin `/api/v1/ws`;
- contain all required runtime assets and configuration.

It does not need to expose a host port or proxy API requests itself. Only run
container images that you trust.

## Configuration, updates and backups

The installer creates `.env` with mode `600`; it is excluded from Git. To pull
the configured images and restart the selected mode:

```bash
cd voxhold-deploy
./update.sh
```

Create a consistent SQLite backup with:

```bash
./backup.sh
```

The backup briefly stops the backend and keeps the Docker volumes intact.

If an existing SQLite volume was created by an older root container, repair its
ownership once before the first start:

```bash
docker volume ls | grep voxhold_data
docker run --rm --user 0 \
  -v <volume-name>:/app/data \
  alpine:3.22 \
  sh -c 'chown -R 10001:10001 /app/data && chmod 770 /app/data'
```
