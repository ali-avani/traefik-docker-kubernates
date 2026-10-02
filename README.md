# Traefik for Docker and Kubernetes

Traefik as a reverse proxy for Docker containers, optionally together with
Kubernetes Ingress. It handles HTTPS with Let's Encrypt and has a password-protected
dashboard. An install script sets it up.

| Install type | What it runs |
| ------------ | ------------ |
| `docker` | Traefik with the Docker provider |
| `kubernetes` | Docker provider plus the Kubernetes Ingress and CRD providers |

## Requirements

- Docker with Docker Compose v2
- `htpasswd` or `openssl`, to hash the dashboard password
- A DNS record for the dashboard domain pointing at this server (Let's Encrypt HTTP challenge)
- `kubernetes` only: `kubectl` for the cluster, allowed to apply cluster-wide RBAC

## Install

```bash
bash ./install.sh
```

It asks for the install type, the dashboard domain, the Let's Encrypt email, the admin
user and password, and the Traefik version. Then it writes `.env` and
`dynamic/dashboard.yaml` (domain and hashed password), applies the Kubernetes RBAC and
writes `kubeconfig.yaml` for `kubernetes`, and starts Traefik.

```bash
bash ./install.sh --yes          # never prompt
bash ./install.sh --no-start     # write the configuration only
bash ./install.sh --update-env   # rebuild .env from .env.sample, keep your values
```

Values are read from the environment or `.env` first. The password is never stored, so
pass it in the environment for an unattended install:

```bash
INSTALL_TYPE=docker DASHBOARD_DOMAIN=traefik.example.com ACME_EMAIL=ops@example.com \
  ADMIN_PASSWORD='change-me-please' bash ./install.sh --yes
```

| Variable | Description |
| -------- | ----------- |
| `INSTALL_TYPE` | `docker` or `kubernetes` |
| `DASHBOARD_DOMAIN` | Domain of the dashboard |
| `ACME_EMAIL` | Email for Let's Encrypt |
| `ADMIN_USER` | Dashboard user (default `admin`) |
| `TRAEFIK_VERSION` | Image tag (default `v3.7`) |
| `TRAEFIK_IMAGE` | Image repository, for a mirror (default `traefik`) |
| `TRAEFIK_LOG_LEVEL` | `DEBUG`, `INFO`, `WARN` or `ERROR` (default `INFO`) |
| `KUBECTL_CONTEXT` `K8S_API_SERVER` | `kubernetes` only: kubectl context and API URL for `kubeconfig.yaml` |
| `COMPOSE_FILE` | Set by the installer |

To upgrade Traefik, change `TRAEFIK_VERSION` and run `docker compose up -d`. Read the
release notes first, because options can change between versions.

## How it works

- `docker-compose.yaml` is the base stack. Its static configuration is `TRAEFIK_*`
  environment variables (Traefik does not allow mixing them with command-line flags),
  so overlays can add to it.
- `kubernetes/` holds the Kubernetes overlay and the RBAC (`traefik.yaml`). The
  installer adds the overlay to `COMPOSE_FILE` for the `kubernetes` type.
- `COMPOSE_FILE` in `.env` is read by Docker Compose v2. Tools that ignore it, such as
  `podman-compose`, need `-f` for each file.
- HTTPS and the `le` certificate resolver are the default on the `websecure` entry
  point, so containers need no `tls` or `certresolver` labels.
- `kubernetes/traefik.yaml` creates a long-lived token Secret for the `traefik`
  ServiceAccount. `kubectl create token` expires after one hour. Delete the Secret to
  revoke access.

## Per-server changes

Settings only some servers need stay out of the repo. Samples are in `examples/`.

- **`docker-compose.override.yaml`** (git-ignored): copy `examples/docker-compose.override.yaml`,
  uncomment what you need, then run `bash ./install.sh --update-env`. Use it for a longer
  read timeout, extra mounts, a certificate volume or any other `TRAEFIK_*` option.
- **`dynamic/`** (git-ignored except `.gitkeep`): put per-server files here, such as
  `examples/registry-transport.yml` or `examples/tls.yml`. Traefik reloads them without a
  restart.
- **Image mirror:** set `TRAEFIK_IMAGE` in `.env` and run `docker compose up -d`.

## Using it

Docker: add labels to a container.

```yaml
services:
  myapp:
    image: myapp:latest
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`myapp.example.com`)"
```

Kubernetes: create an Ingress with `ingressClassName: traefik`.

## Files

```
install.sh                      installer
docker-compose.yaml             base stack
docker-compose.override.yaml    your changes (not committed)
kubernetes/                     Kubernetes overlay and RBAC
dynamic/                        file provider directory (dashboard.yaml is generated)
examples/                       override, servers transport and own-certificate samples
.env.sample                     variables
```

## Troubleshooting

- Logs: `docker compose logs -f traefik`.
- Kubernetes access: `kubectl auth can-i get ingresses --as=system:serviceaccount:kube-system:traefik`.
- If ufw is active, allow ports 80 and 443. Traefik runs on the host network, so Docker's
  own firewall rules do not open them.

## Stopping

```bash
docker compose down        # keeps certificates in ./letsencrypt
```
