# Traefik Docker + Kubernetes Setup

Traefik as a reverse proxy and load balancer for Docker containers, optionally
together with Kubernetes Ingress resources. It includes automatic SSL
certificates via Let's Encrypt and a password-protected dashboard.

An install script sets everything up. You choose one of two installation types:

| Type         | What it does                                                          |
| ------------ | --------------------------------------------------------------------- |
| `docker`     | Traefik with the Docker provider only                                 |
| `kubernetes` | Docker provider plus the Kubernetes Ingress and CRD providers         |

## Prerequisites

- Docker with Docker Compose v2 (`docker compose`)
- `htpasswd` (apache2-utils / httpd-tools) or `openssl`, to hash the dashboard password
- For `kubernetes` only: `kubectl` configured for the cluster, with permission to
  apply cluster-wide RBAC
- A DNS record for the dashboard domain pointing at this server (needed for the
  Let's Encrypt HTTP challenge)

## Install

```bash
./install.sh
```

The script asks for:

- installation type (`docker` or `kubernetes`)
- dashboard domain, for example `traefik.example.com`
- Let's Encrypt email
- dashboard admin username and password
- Traefik version (default `v3.7`)

Then it:

1. saves the answers to `.env` (the password is never saved)
2. writes `dynamic/dashboard.yaml` with the domain and a hashed password
3. for `kubernetes`: applies `traefik.yaml` (IngressClass, ServiceAccount, RBAC,
   token Secret) with `kubectl`, then writes `kubeconfig.yaml` from the cluster CA,
   the ServiceAccount token and the API server URL
4. starts Traefik with `docker compose up -d` (asks first)

Options:

```bash
./install.sh --yes        # never prompt, fail if a value is missing
./install.sh --no-start   # write the configuration only
```

### Unattended install with `.env`

Every value is read from the environment or `.env` first, and only asked for
when missing:

```bash
cp .env.sample .env
# fill in INSTALL_TYPE, DASHBOARD_DOMAIN, ACME_EMAIL, ADMIN_USER, ADMIN_PASSWORD
./install.sh --yes
```

| Variable            | Description                                                          |
| ------------------- | -------------------------------------------------------------------- |
| `INSTALL_TYPE`      | `docker` or `kubernetes`                                             |
| `DASHBOARD_DOMAIN`  | Domain for the dashboard                                             |
| `ACME_EMAIL`        | Email for Let's Encrypt                                              |
| `ADMIN_USER`        | Dashboard username (default `admin`)                                 |
| `ADMIN_PASSWORD`    | Dashboard password, read only by the installer, which clears it from `.env` |
| `ADMIN_PASSWORD_HASH` | Instead of `ADMIN_PASSWORD`: a ready htpasswd hash (single-quote it in `.env`) |
| `TRAEFIK_VERSION`   | Traefik image tag (default `v3.7`)                                   |
| `TRAEFIK_IMAGE`     | Image repository, to use a mirror such as `hub.hamdocker.ir/traefik` (default `traefik`) |
| `TRAEFIK_LOG_LEVEL` | `DEBUG`, `INFO`, `WARN` or `ERROR` (default `INFO`)                  |
| `KUBECTL_CONTEXT`   | Kubernetes only: kubectl context (default: current)                  |
| `K8S_API_SERVER`    | Kubernetes only: API URL for `kubeconfig.yaml` (default: from kubectl) |
| `COMPOSE_FILE`      | Set by the installer, selects the compose files                      |

To change the Traefik version later, edit `TRAEFIK_VERSION` in `.env` and run
`docker compose up -d`.

## How it works

- `docker-compose.yaml` is the base stack (Docker provider only).
- `docker-compose.kubernetes.yaml` is an overlay that adds the Kubernetes
  providers and mounts `kubeconfig.yaml`. The installer enables it by setting
  `COMPOSE_FILE=docker-compose.yaml:docker-compose.kubernetes.yaml` in `.env`.
- Static configuration is passed as `TRAEFIK_*` environment variables, so the
  overlay can add to it. Traefik does not allow mixing flags and environment
  variables.
- `COMPOSE_FILE` in `.env` is read by Docker Compose v2. If your tool ignores it
  (for example `podman-compose`), pass the files with `-f` instead.

To switch the installation type, run `./install.sh` again with a different
`INSTALL_TYPE`.

## Custom configuration per server

Settings that only some servers need are kept out of the repo. Examples are in
`examples/`.

### Compose customizations: `docker-compose.override.yaml`

Copy `examples/docker-compose.override.yaml` to `./docker-compose.override.yaml`,
uncomment what you need, then run `./install.sh` again. The installer adds the file
to `COMPOSE_FILE`. The file is git-ignored.

Compose merges it into `docker-compose.yaml`: new environment keys are added, and
a volume with the same container path replaces the base one. Examples:

- **Longer read timeout** (for example for container registry pushes):
  `TRAEFIK_ENTRYPOINTS_WEBSECURE_TRANSPORT_RESPONDINGTIMEOUTS_READTIMEOUT: 1800s`
- **Certificate storage in a named volume** instead of `./letsencrypt`:
  `- traefik-certs:/letsencrypt`, plus the top-level `volumes:` declaration
- **Extra mounts**, for example `/root/ssl:/certs:ro`
- Any other static option as `TRAEFIK_*` environment variable, for example
  `TRAEFIK_PROVIDERS_DOCKER_NETWORK`

### Dynamic configuration: `dynamic/`

Everything in `dynamic/` except `.gitkeep` is git-ignored. Put per-server files
there, for example `examples/registry-transport.yml` (servers transport with
longer timeouts) or `examples/tls.yml` (your own certificate). Traefik reloads
them without a restart.

### Image mirror

Set `TRAEFIK_IMAGE` in `.env`, for example `TRAEFIK_IMAGE=hub.hamdocker.ir/traefik`,
and run `docker compose up -d`.

## Configuration details

### Ports and entry points

- **Port 80 (web)**: HTTP traffic, redirects to HTTPS
- **Port 443 (websecure)**: HTTPS traffic, default entry point

### SSL certificates

- Automatic certificates via Let's Encrypt, HTTP challenge
- Stored in `./letsencrypt/acme.json`

### Dashboard

Available at `https://<DASHBOARD_DOMAIN>` with the username and password you
gave the installer. To change the password, set `ADMIN_PASSWORD` and run
`./install.sh --yes` again, or edit `dynamic/dashboard.yaml` with a hash from
`htpasswd -nB username`.

### Providers

- Docker containers (with labels)
- Kubernetes Ingress and CRDs (`kubernetes` type only)
- File configuration in `./dynamic/`

### Kubernetes access

`traefik.yaml` creates a `traefik` ServiceAccount with read-only RBAC and a
`traefik-token` Secret with a long-lived token. The old approach,
`kubectl create token`, expires after one hour. The token ends up in
`kubeconfig.yaml` (mode 600, not committed). Delete the Secret to revoke it.

## Directory structure

```
.
├── install.sh                      # Interactive / unattended installer
├── docker-compose.yaml             # Base stack (Docker provider)
├── docker-compose.kubernetes.yaml  # Overlay: Kubernetes providers
├── traefik.yaml                    # Kubernetes IngressClass, RBAC, token Secret
├── dynamic/                        # File provider directory (contents not committed)
│   └── dashboard.yaml              # Generated by install.sh
├── examples/                       # Samples for per-server customizations
│   ├── docker-compose.override.yaml
│   ├── registry-transport.yml
│   └── tls.yml
├── docker-compose.override.yaml    # Your local customizations (not committed)
├── .env.sample                     # Variables template
├── kubeconfig.yaml                 # Generated by install.sh (not committed)
└── README.md
```

## Usage

### Docker services

Add labels to a container:

```yaml
services:
  myapp:
    image: myapp:latest
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`myapp.example.com`)"
      - "traefik.http.routers.myapp.tls.certresolver=le"
```

### Kubernetes Ingress (`kubernetes` type)

Create standard Ingress resources with `ingressClassName: traefik`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp-ingress
spec:
  ingressClassName: traefik
  rules:
    - host: myapp.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp-service
                port:
                  number: 80
```

## Troubleshooting

```bash
docker compose logs -f traefik
kubectl auth can-i get ingresses --as=system:serviceaccount:kube-system:traefik
```

## Security notes

- The dashboard is protected with HTTP Basic Authentication
- HTTP is redirected to HTTPS
- Traefik has read-only access to the Docker socket
- Kubernetes access is limited by RBAC rules
- `.env` and `kubeconfig.yaml` are created with mode 600 and are git-ignored
- The compose file does not pass `.env` to the container, so the admin password
  is not exposed in the container environment

## Stopping

```bash
docker compose down
```

To also remove the Let's Encrypt certificates:

```bash
rm -rf letsencrypt/
```
