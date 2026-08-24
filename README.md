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

If the owner password prompt is left empty, the installer generates it during
the first bootstrap and prints it in the final installation summary. Save it
immediately: it cannot be recovered from the database later.

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

If no domain is available, leave the public host empty. The installer detects
the server's external IP over HTTPS and uses it for Caddy and WebRTC. When a
domain is entered, the detected server IP is offered separately as the WebRTC
address.

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

With the optional built-in TURN relay, additionally allow `3478/tcp`,
`3478/udp` and the relay range `49160-49559/udp` (see below). Do not close
`50000/udp` or `50001/udp` after enabling TURN: direct server-mode media would
otherwise be forced through the relay with extra latency.

Backend and frontend HTTP ports are available only inside the Compose network.
For a domain, Caddy obtains and renews its publicly trusted certificate. For a
bare public IPv4 or IPv6 address, the installer obtains a publicly trusted
short-lived Let's Encrypt certificate with Caddy. No certificate needs to be
installed on client devices.

IP certificates are valid for about six days. Caddy begins renewal around
half-life, retries temporary ACME or network failures, and checks the stored
certificate immediately whenever the container starts. A renewal missed while
the server was powered off is therefore recovered after the next start. Keep
the `caddy_data` Docker volume: it contains the ACME account, certificates and
keys. The public IP must remain assigned to the server, and ports `80/tcp` and
`443/tcp` must remain reachable for ACME validation.

## WebRTC ICE configuration and TURN

Browsers never receive TURN credentials at build time. The runtime path is:

```text
.env -> backend -> authenticated GET /api/v1/webrtc/config -> browser
```

The backend serves the `WEBRTC_CLIENT_ICE_*` values to authorized browser
clients with `iceTransportPolicy: all`, so direct UDP stays the preferred
route and TURN is only a fallback. Changing TURN settings requires just a
backend restart — the frontend does not need to be rebuilt.

The separate `WEBRTC_SERVER_ICE_*` variables configure the backend's own Pion
sessions. They stay empty in the standard public deployment, where the backend
publishes host candidates directly through `WEBRTC_PUBLIC_IP` and its UDP
ports; feeding TURN to Pion would create needless relay allocations per voice
or stream session.

### Built-in coturn (profile "turn")

coturn uses host networking: it binds `TURN_LISTEN_PORT` (`3478` by default,
TCP and UDP) and the relay range directly on the host. Required firewall ports:

- `3478/tcp` + `3478/udp` — TURN client transport;
- `49160-49559/udp` — relay allocations (`TURN_RELAY_PORT_MIN`–`MAX`).

Because one shared `TURN_USERNAME` serves all clients, `TURN_USER_QUOTA` must
remain `0`; the overall allocation limit is `TURN_TOTAL_QUOTA`, sized to the
relay range (roughly one port per allocation). Widen the range and the
matching firewall rules together — a quota above the real port capacity would
break allocations under load.

### Networks that block plain TURN

Corporate networks sometimes block TURN over UDP and TCP. The built-in coturn
runs without TLS and cannot offer `turns:` on the same IP because Caddy owns
`443/tcp`. Use an external managed TURN provider with a URL such as
`turns:turn.example.com:443?transport=tcp`, and put it into
`WEBRTC_CLIENT_ICE_SERVERS`.

### Checking the runtime endpoint safely

The endpoint response contains credentials. Verify it with an authorized
request without printing the full JSON:

```bash
curl -fsS \
  -H "Authorization: Bearer $VOXHOLD_TEST_TOKEN" \
  https://voxhold.example.com/api/v1/webrtc/config \
  | jq '{urls: [.ice_servers[].urls], policy: .ice_transport_policy}'
```

Do not store bearer tokens or full responses in shell history or CI artifacts.
See [README.webrtc-fixes.ru.md](README.webrtc-fixes.ru.md) for migration and
smoke-test details.

## Container images

The defaults are:

```text
ghcr.io/looneman1/voxhold-backend:latest
ghcr.io/looneman1/voxhold-frontend:latest
```

Backend and frontend references are independent and accept both tags and
digests:

```dotenv
VOXHOLD_BACKEND_IMAGE=ghcr.io/looneman1/voxhold-backend:latest
VOXHOLD_FRONTEND_IMAGE=ghcr.io/example/custom-voxhold-ui@sha256:<digest>
```

Backend images are published only from Git tags such as `v0.1.0`. The image
tags `0.1.0`, `0.1` and `latest` then point to that release. Deploy uses
`latest` by default, so `./update.sh` pulls the latest stable backend. Use an
exact tag or OCI digest when a production deployment must remain pinned.
Private images require
`docker login` before installation or update. Migration and bootstrap jobs
always use exactly the same image reference as the backend service.

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

The installer creates `.env` with mode `600`; it is excluded from Git. The
chosen deployment mode and TURN option are persisted as `COMPOSE_PROFILES`, so
plain `docker compose up`, `pull` and `down` commands operate on exactly the
services selected during installation. To pull the currently configured images
and restart the selected mode:

```bash
cd voxhold-deploy
./update.sh
```

Certificate management requires no separate cron job or systemd timer. Inspect
Caddy's status and certificate activity with:

```bash
docker compose ps caddy
docker compose logs --tail=100 caddy
```

Both domain and IP certificate state is stored in the persistent `caddy_data`
volume.

To switch the official backend to another exact release and update the stack:

```bash
./backup.sh
./update.sh --backend-version 0.2.0
```

The command also accepts the Git-style form `v0.2.0`. It deliberately replaces
`VOXHOLD_BACKEND_IMAGE` with the official GHCR image; edit `.env` directly when
using a fork, custom registry or immutable digest. Review release notes and
make a backup before changing versions.

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
