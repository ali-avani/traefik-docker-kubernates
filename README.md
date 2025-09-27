# Traefik Docker + Kubernetes Setup

This project sets up Traefik as a reverse proxy and load balancer that works with both Docker containers and Kubernetes ingress resources. It includes automatic SSL certificate generation via Let's Encrypt and a secure dashboard.

## Prerequisites

- Docker and Docker Compose
- Kubernetes cluster access
- `kubectl` configured and working
- `htpasswd` utility (usually comes with Apache utils)

## Setup Instructions

### 1. Copy and Configure Environment File

First, create your environment configuration:

```bash
cp .env.sample .env
```

Edit the `.env` file and fill in the required values:

- `ACME_EMAIL`: Your email address for Let's Encrypt certificate registration

### 2. Apply Traefik Kubernetes Resources

Apply the Traefik RBAC and ServiceAccount configuration to your Kubernetes cluster:

```bash
kubectl apply -f traefik.yaml
```

This creates:

- `traefik` IngressClass
- `traefik` ServiceAccount in `kube-system` namespace
- ClusterRole and ClusterRoleBinding for proper permissions

### 3. Replace Placeholders in YAML Files

Update the configuration files with your specific values:

#### In `dynamic/dashboard.yaml`:

- Replace `<dashboard-domain>` with your actual dashboard domain (e.g., `traefik.yourdomain.com`)

#### In `kubeconfig.sample.yaml`:

- Replace `<certificate-authority-data>` with your cluster's CA data
- Replace `<token>` with the Traefik service account token

### 4. Generate Dashboard Authentication

Create a username and password for the Traefik dashboard:

```bash
htpasswd -nB username
```

Replace `username` with your desired username. This command will prompt for a password and output a string like `username:$2y$10$...`.

Copy this output and replace the `username:password` line in `dynamic/dashboard.yaml` under the `users` section.

### 5. Configure Kubernetes Access

#### Get Certificate Authority Data

```bash
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'
```

#### Create Service Account Token

```bash
kubectl -n kube-system create token traefik
```

Copy the kubeconfig template and fill in the values:

```bash
cp kubeconfig.sample.yaml kubeconfig.yaml
```

Edit `kubeconfig.yaml` and replace:

- `<certificate-authority-data>` with the output from the certificate command
- `<token>` with the output from the token command

### 6. Start Traefik

Create the Let's Encrypt directory and start the services:

```bash
mkdir -p letsencrypt
docker compose up -d
```

## Configuration Details

### Ports and Entry Points

- **Port 80 (web)**: HTTP traffic, automatically redirects to HTTPS
- **Port 443 (websecure)**: HTTPS traffic, default entry point

### SSL Certificates

- Automatic SSL certificate generation via Let's Encrypt
- HTTP challenge validation
- Certificates stored in `./letsencrypt/acme.json`

### Dashboard Access

Once running, access the Traefik dashboard at:

- `https://<dashboard-domain>` (configured in `dynamic/dashboard.yaml`)
- Use the username/password you generated with `htpasswd`

### Providers

Traefik is configured to watch:

- Docker containers (with labels)
- Kubernetes Ingress resources
- Kubernetes CRDs (IngressRoute, etc.)
- File-based configuration in `./dynamic/`

## Directory Structure

```
.
├── docker-compose.yaml     # Main Traefik container configuration
├── traefik.yaml           # Kubernetes RBAC and ServiceAccount
├── dynamic/
│   └── dashboard.yaml     # Dashboard routing and authentication
├── kubeconfig.sample.yaml # Template for Kubernetes access
├── .env.sample           # Environment variables template
└── README.md             # This file
```

## Usage

### Docker Services

To expose a Docker service through Traefik, add labels to your container:

```yaml
services:
  myapp:
    image: myapp:latest
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`myapp.example.com`)"
      - "traefik.http.routers.myapp.tls.certresolver=le"
```

### Kubernetes Ingress

Create standard Kubernetes Ingress resources with `ingressClassName: traefik`:

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

### Check Traefik Logs

```bash
docker compose logs -f traefik
```

### Verify Kubernetes Permissions

```bash
kubectl auth can-i get ingresses --as=system:serviceaccount:kube-system:traefik
```

## Security Notes

- The dashboard is protected with HTTP Basic Authentication
- All HTTP traffic is automatically redirected to HTTPS
- Let's Encrypt certificates are automatically renewed
- Traefik has read-only access to Docker socket
- Kubernetes access is limited by RBAC rules

## Stopping the Service

```bash
docker compose down
```

To also remove the Let's Encrypt certificates:

```bash
docker compose down -v
rm -rf letsencrypt/
```
