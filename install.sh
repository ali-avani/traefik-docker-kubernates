#!/usr/bin/env bash
# Traefik installer: Docker only, or Docker + Kubernetes.
#
# Values come from the environment or .env, and are asked for when missing.
#
# Usage: bash ./install.sh [--yes] [--no-start] | --update-env
#   --yes, -y     never prompt; fail if a required value is missing
#   --no-start    write the configuration but do not start Traefik
#   --update-env  rebuild .env from .env.sample, keep your values, then exit

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ENV_FILE=".env"
YES=false; START=true; MODE=install

die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

for arg in "$@"; do
    case "$arg" in
        --yes|-y)     YES=true ;;
        --no-start)   START=false ;;
        --update-env) MODE=update-env ;;
        -h|--help)    sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *)            die "unknown option: $arg (see --help)" ;;
    esac
done
[[ -t 0 ]] || YES=true

# ------------------------------------------------------------------ .env

# Read KEY=VALUE lines from .env into the environment. Variables that are
# already set win. The file is parsed, not sourced.
load_env() {
    local line key val
    [[ -f "$ENV_FILE" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
        [[ "$val" =~ ^\'(.*)\'$ || "$val" =~ ^\"(.*)\"$ ]] && val="${BASH_REMATCH[1]}"
        [[ -n "${!key:-}" ]] || export "$key=$val"
    done < "$ENV_FILE"
}

# Plain when safe, single-quoted otherwise.
quote() {
    if [[ "$1" =~ ^[A-Za-z0-9._:/@+,=-]+$ ]]; then printf '%s' "$1"
    else printf "'%s'" "${1//\'/\'\\\'\'}"; fi
}

# Rebuild .env from .env.sample: same comments and order, each key set to its
# current value. Keys that are not in the sample are kept at the end.
write_env() {
    local tmp line key other; tmp="$(mktemp)"
    while IFS= read -r line; do
        if [[ "$line" =~ ^(#[[:space:]]*)?([A-Z][A-Z0-9_]*)= && -n "${!BASH_REMATCH[2]:-}" ]]; then
            key="${BASH_REMATCH[2]}"; line="$key=$(quote "${!key}")"
        fi
        echo "$line"
    done < .env.sample > "$tmp"
    other="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" 2>/dev/null | grep -v '^ADMIN_PASSWORD=' | while IFS= read -r line; do
        grep -qE "^#?[[:space:]]*${line%%=*}=" .env.sample || echo "$line"
    done || true)"
    [[ -z "$other" ]] || printf '\n# Other settings kept from the previous %s\n%s\n' "$ENV_FILE" "$other" >> "$tmp"
    cat "$tmp" > "$ENV_FILE"; chmod 600 "$ENV_FILE"; rm -f "$tmp"
}

# ------------------------------------------------------------------ prompts

# ask VAR "Prompt" [default]: keep VAR if set, else prompt. Without a terminal
# (--yes) the default is used, and a missing default is an error.
ask() {
    local var="$1" prompt="$2" default="${3:-}" reply
    [[ -n "${!var:-}" ]] && return 0
    if $YES; then
        [[ -n "$default" ]] || die "$var is not set (set it in the environment or $ENV_FILE)"
        printf -v "$var" '%s' "$default"; return 0
    fi
    read -r -p "$prompt${default:+ [$default]}: " reply
    reply="${reply:-$default}"
    [[ -n "$reply" ]] || die "$var is required"
    printf -v "$var" '%s' "$reply"
}

# ask_secret VAR "Prompt": hidden, entered twice, at least 8 characters.
ask_secret() {
    local var="$1" p1 p2
    [[ -n "${!var:-}" ]] && return 0
    $YES && die "$var is not set (set it in the environment or $ENV_FILE)"
    while :; do
        read -r -s -p "$2: " p1; echo
        read -r -s -p "Repeat: " p2; echo
        [[ "$p1" == "$p2" && ${#p1} -ge 8 ]] && break
        echo "The values must match and have at least 8 characters."
    done
    printf -v "$var" '%s' "$p1"
}

# ------------------------------------------------------------------ steps

compose() {
    if docker compose version >/dev/null 2>&1; then docker compose "$@"
    else docker-compose "$@"; fi
}

# Compose files in use, stored in .env so that plain "docker compose" works.
build_compose() {
    export COMPOSE_FILE="docker-compose.yaml"
    [[ "$INSTALL_TYPE" != "kubernetes" ]] || COMPOSE_FILE+=":kubernetes/docker-compose.yaml"
    if [[ -f docker-compose.override.yaml ]]; then
        COMPOSE_FILE+=":docker-compose.override.yaml"
        info "Using docker-compose.override.yaml"
    fi
}

# Prints "user:hash" for Traefik basicAuth. The password goes through stdin.
hash_password() {
    if command -v htpasswd >/dev/null 2>&1; then
        printf '%s\n' "$2" | htpasswd -niBC 10 "$1"
    elif command -v openssl >/dev/null 2>&1; then
        printf '%s:%s\n' "$1" "$(printf '%s' "$2" | openssl passwd -apr1 -stdin)"
    else
        die "need htpasswd or openssl to hash the password"
    fi
}

write_dashboard() {
    local entry; entry="$(hash_password "$ADMIN_USER" "$ADMIN_PASSWORD")"
    mkdir -p dynamic
    cat > dynamic/dashboard.yaml <<EOF
http:
  routers:
    traefik-dashboard:
      rule: Host(\`${DASHBOARD_DOMAIN}\`)
      service: api@internal
      middlewares:
        - traefik-auth@file
  middlewares:
    traefik-auth:
      basicAuth:
        users:
          - "${entry}"
EOF
    info "Wrote dynamic/dashboard.yaml"
}

# Apply the RBAC, then write kubeconfig.yaml from the cluster CA and the token.
setup_kubernetes() {
    command -v kubectl >/dev/null 2>&1 || die "kubectl is required for the kubernetes installation"
    local kctl=(kubectl) token="" ca ca_file server i
    [[ -z "${KUBECTL_CONTEXT:-}" ]] || kctl+=(--context "$KUBECTL_CONTEXT")
    "${kctl[@]}" cluster-info >/dev/null 2>&1 || die "cannot reach the cluster with kubectl"

    "${kctl[@]}" apply -f kubernetes/traefik.yaml
    for i in $(seq 1 30); do
        token="$("${kctl[@]}" -n kube-system get secret traefik-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
        [[ -n "$token" ]] && break
        sleep 1
    done
    [[ -n "$token" ]] || die "secret kube-system/traefik-token has no token yet"

    ca="$("${kctl[@]}" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
    if [[ -z "$ca" ]]; then
        ca_file="$("${kctl[@]}" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}')"
        [[ -f "$ca_file" ]] && ca="$(base64 < "$ca_file" | tr -d '\n')"
    fi
    [[ -n "$ca" ]] || die "could not read the cluster CA from kubectl config"

    server="$("${kctl[@]}" config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')"
    ask K8S_API_SERVER "Kubernetes API server URL" "$server"

    ( umask 077
      cat > kubeconfig.yaml <<EOF
apiVersion: v1
kind: Config
clusters:
- name: default
  cluster:
    certificate-authority-data: ${ca}
    server: ${K8S_API_SERVER}
contexts:
- name: traefik@default
  context:
    cluster: default
    user: traefik
current-context: traefik@default
users:
- name: traefik
  user:
    token: ${token}
EOF
    )
    info "Wrote kubeconfig.yaml"
}

# ------------------------------------------------------------------ install

install() {
    ask INSTALL_TYPE "Install type: docker or kubernetes" "docker"
    [[ "$INSTALL_TYPE" =~ ^(docker|kubernetes)$ ]] || die "INSTALL_TYPE must be docker or kubernetes"
    ask DASHBOARD_DOMAIN "Dashboard domain (e.g. traefik.example.com)"
    ask ACME_EMAIL "Email for Let's Encrypt"
    ask ADMIN_USER "Dashboard admin username" "admin"
    ask_secret ADMIN_PASSWORD "Admin password for '$ADMIN_USER'"
    ask TRAEFIK_VERSION "Traefik version" "v3.7"
    [[ "$DASHBOARD_DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || die "invalid DASHBOARD_DOMAIN: $DASHBOARD_DOMAIN"
    [[ "$ADMIN_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "ADMIN_USER may only contain letters, digits, '.', '_' and '-'"
    build_compose

    write_dashboard
    unset ADMIN_PASSWORD
    mkdir -p letsencrypt
    if [[ "$INSTALL_TYPE" == "kubernetes" ]]; then
        setup_kubernetes
        export K8S_API_SERVER
    fi
    write_env
    info "Saved settings to $ENV_FILE"

    if $START; then
        local answer=y
        $YES || read -r -p "Start Traefik now? [Y/n]: " answer
        [[ ! "${answer:-y}" =~ ^[Yy] ]] || compose up -d
    fi

    echo
    echo "Dashboard: https://$DASHBOARD_DOMAIN (user: $ADMIN_USER)"
    echo "Point the DNS record for $DASHBOARD_DOMAIN at this server for the certificate."
}

# ------------------------------------------------------------------ main

load_env
case "$MODE" in
    install)    install ;;
    update-env) unset ADMIN_PASSWORD
                [[ -z "${INSTALL_TYPE:-}" ]] || build_compose   # pick up a new override file
                write_env
                info "Updated $ENV_FILE from .env.sample" ;;
esac
