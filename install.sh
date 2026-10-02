#!/usr/bin/env bash
# Traefik installer: Docker only, or Docker + Kubernetes.
#
# Every value is read from the environment or from .env first and only asked
# for when missing. Chosen values are saved back to .env (except the password).
#
# Usage: ./install.sh [--yes] [--no-start]
#   --yes, -y    never prompt; fail if a required value is missing
#   --no-start   write the configuration but do not start Traefik

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ENV_FILE=".env"
NON_INTERACTIVE=false
START=true

die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "Warning: $*" >&2; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
    case "$arg" in
        --yes|-y)   NON_INTERACTIVE=true ;;
        --no-start) START=false ;;
        -h|--help)  usage; exit 0 ;;
        *)          die "unknown option: $arg (see --help)" ;;
    esac
done
[[ -t 0 ]] || NON_INTERACTIVE=true

# Load KEY=VALUE lines from .env without overriding variables that are already
# set in the environment. The file is parsed, not sourced.
load_env() {
    [[ -f "$ENV_FILE" ]] || return 0
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        if [[ "$val" =~ ^\'(.*)\'$ || "$val" =~ ^\"(.*)\"$ ]]; then
            val="${BASH_REMATCH[1]}"
        fi
        if [[ -z "${!key:-}" ]]; then
            export "$key=$val"
        fi
    done < "$ENV_FILE"
}

# Print a .env value: plain when safe, single-quoted otherwise.
quote_env() {
    if [[ "$1" =~ ^[A-Za-z0-9._:/@+,=-]+$ ]]; then
        printf '%s' "$1"
    else
        printf "'%s'" "${1//\'/\'\\\'\'}"
    fi
}

write_env() {
    local sample=".env.sample" tmp line key val known=" "
    local other=()
    [[ -f "$sample" ]] || die "$sample not found"
    tmp="$(mktemp)"

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^(#[[:space:]]*)?([A-Z][A-Z0-9_]*)= ]]; then
            key="${BASH_REMATCH[2]}"
            known+="$key "
            val="${!key:-}"
            if [[ -n "$val" ]]; then
                line="${key}=$(quote_env "$val")"
            fi
        fi
        printf '%s\n' "$line"
    done < "$sample" > "$tmp"

    if [[ -f "$ENV_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
            key="${BASH_REMATCH[1]}"
            [[ "$known" == *" $key "* ]] && continue
            other+=("$line")
        done < "$ENV_FILE"
    fi
    if [[ ${#other[@]} -gt 0 ]]; then
        { echo; echo "# Other settings kept from the previous $ENV_FILE"; printf '%s\n' "${other[@]}"; } >> "$tmp"
    fi

    cat "$tmp" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    rm -f "$tmp"
}

# ask VAR "Prompt" [default]: keep VAR if already set, else prompt (or use the
# default when non-interactive).
ask() {
    local var="$1" prompt="$2" default="${3:-}" reply
    [[ -n "${!var:-}" ]] && return 0
    if $NON_INTERACTIVE; then
        [[ -n "$default" ]] || die "$var is not set (set it in the environment or $ENV_FILE)"
        printf -v "$var" '%s' "$default"
        return 0
    fi
    while :; do
        if [[ -n "$default" ]]; then
            read -r -p "$prompt [$default]: " reply
            reply="${reply:-$default}"
        else
            read -r -p "$prompt: " reply
        fi
        [[ -n "$reply" ]] && break
        echo "A value is required."
    done
    printf -v "$var" '%s' "$reply"
}

ask_install_type() {
    if [[ -z "${INSTALL_TYPE:-}" ]]; then
        $NON_INTERACTIVE && die "INSTALL_TYPE is not set (docker or kubernetes)"
        echo "Installation type:"
        echo "  1) docker      Traefik with the Docker provider only"
        echo "  2) kubernetes  Docker provider + Kubernetes Ingress and CRDs"
        local reply
        while :; do
            read -r -p "Choose [1-2] (default 1): " reply
            case "${reply:-1}" in
                1|docker)     INSTALL_TYPE=docker; break ;;
                2|kubernetes) INSTALL_TYPE=kubernetes; break ;;
                *) echo "Enter 1 or 2." ;;
            esac
        done
    fi
    case "$INSTALL_TYPE" in
        docker|kubernetes) ;;
        *) die "INSTALL_TYPE must be 'docker' or 'kubernetes', got '$INSTALL_TYPE'" ;;
    esac
}

ask_password() {
    [[ -n "${ADMIN_PASSWORD:-}" ]] && return 0
    $NON_INTERACTIVE && die "ADMIN_PASSWORD is not set (set it in the environment or $ENV_FILE)"
    local p1 p2
    while :; do
        read -r -s -p "Admin password for '$ADMIN_USER': " p1; echo
        [[ ${#p1} -ge 8 ]] || { echo "Use at least 8 characters."; continue; }
        read -r -s -p "Repeat password: " p2; echo
        [[ "$p1" == "$p2" ]] && break
        echo "Passwords do not match."
    done
    ADMIN_PASSWORD="$p1"
}

hash_password() {
    local user="$1" pass="$2"
    if command -v htpasswd >/dev/null 2>&1; then
        printf '%s\n' "$pass" | htpasswd -niBC 10 "$user"
    elif command -v openssl >/dev/null 2>&1; then
        printf '%s:%s\n' "$user" "$(printf '%s' "$pass" | openssl passwd -apr1 -stdin)"
    else
        die "need htpasswd (apache2-utils / httpd-tools) or openssl to hash the password"
    fi
}

compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    else
        die "docker compose is not installed"
    fi
}

validate_inputs() {
    [[ "$DASHBOARD_DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] \
        || die "invalid DASHBOARD_DOMAIN: $DASHBOARD_DOMAIN"
    [[ "$ACME_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] \
        || die "invalid ACME_EMAIL: $ACME_EMAIL"
    [[ "$ADMIN_USER" =~ ^[A-Za-z0-9._-]+$ ]] \
        || die "ADMIN_USER may only contain letters, digits, '.', '_' and '-'"
    [[ "$TRAEFIK_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] \
        || die "invalid TRAEFIK_VERSION: $TRAEFIK_VERSION"
    [[ -z "${TRAEFIK_IMAGE:-}" || "$TRAEFIK_IMAGE" =~ ^[A-Za-z0-9._:/-]+$ ]] \
        || die "invalid TRAEFIK_IMAGE: $TRAEFIK_IMAGE"
    [[ -z "${ADMIN_PASSWORD_HASH:-}" || "$ADMIN_PASSWORD_HASH" != *[\"[:space:]]* ]] \
        || die "ADMIN_PASSWORD_HASH must not contain spaces or double quotes"
}

build_compose_file() {
    COMPOSE_FILE="docker-compose.yaml"
    [[ "$INSTALL_TYPE" == "kubernetes" ]] && COMPOSE_FILE+=":docker-compose.kubernetes.yaml"
    if [[ -f docker-compose.override.yaml ]]; then
        COMPOSE_FILE+=":docker-compose.override.yaml"
        info "Using docker-compose.override.yaml"
    fi
    export COMPOSE_FILE
}

write_dashboard() {
    local entry
    if [[ -n "${ADMIN_PASSWORD_HASH:-}" ]]; then
        entry="${ADMIN_USER}:${ADMIN_PASSWORD_HASH}"
    else
        entry="$(hash_password "$ADMIN_USER" "$ADMIN_PASSWORD")"
    fi
    mkdir -p dynamic
    umask 077
    cat > dynamic/dashboard.yaml <<EOF
http:
  routers:
    traefik-dashboard:
      rule: Host(\`${DASHBOARD_DOMAIN}\`)
      tls:
        certResolver: le
      service: api@internal
      middlewares:
        - traefik-auth@file
  middlewares:
    traefik-auth:
      basicAuth:
        users:
          - "${entry}"
EOF
    chmod 644 dynamic/dashboard.yaml
    info "Wrote dynamic/dashboard.yaml"
}

setup_kubernetes() {
    command -v kubectl >/dev/null 2>&1 || die "kubectl is required for the kubernetes installation"
    local kctl=(kubectl)
    [[ -n "${KUBECTL_CONTEXT:-}" ]] && kctl+=(--context "$KUBECTL_CONTEXT")

    "${kctl[@]}" cluster-info >/dev/null 2>&1 \
        || die "cannot reach the cluster with kubectl (check your kubeconfig / KUBECTL_CONTEXT)"

    info "Applying traefik.yaml to the cluster"
    "${kctl[@]}" apply -f traefik.yaml

    info "Reading the ServiceAccount token"
    local token="" i
    for i in $(seq 1 30); do
        token="$("${kctl[@]}" -n kube-system get secret traefik-token \
            -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
        [[ -n "$token" ]] && break
        sleep 1
    done
    [[ -n "$token" ]] || die "secret kube-system/traefik-token has no token yet"

    local ca ca_file
    ca="$("${kctl[@]}" config view --raw --minify \
        -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
    if [[ -z "$ca" ]]; then
        ca_file="$("${kctl[@]}" config view --raw --minify \
            -o jsonpath='{.clusters[0].cluster.certificate-authority}')"
        [[ -f "$ca_file" ]] && ca="$(base64 < "$ca_file" | tr -d '\n')"
    fi
    [[ -n "$ca" ]] || die "could not read the cluster CA from kubectl config"

    local default_server
    default_server="$("${kctl[@]}" config view --raw --minify \
        -o jsonpath='{.clusters[0].cluster.server}')"
    ask K8S_API_SERVER "Kubernetes API server URL" "$default_server"

    umask 077
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
    info "Wrote kubeconfig.yaml (mode 600)"
}

main() {
    load_env

    ask_install_type
    ask DASHBOARD_DOMAIN "Dashboard domain (e.g. traefik.example.com)"
    ask ACME_EMAIL "Email for Let's Encrypt"
    ask ADMIN_USER "Dashboard admin username" "admin"
    [[ -n "${ADMIN_PASSWORD_HASH:-}" ]] || ask_password
    ask TRAEFIK_VERSION "Traefik version" "v3.7"
    validate_inputs
    build_compose_file

    write_dashboard
    unset ADMIN_PASSWORD     # only needed to hash it; keep it out of .env
    write_env
    info "Saved settings to $ENV_FILE"
    mkdir -p letsencrypt

    if [[ "$INSTALL_TYPE" == "kubernetes" ]]; then
        setup_kubernetes
        export K8S_API_SERVER
        write_env
    fi

    if $START; then
        local answer=y
        if ! $NON_INTERACTIVE; then
            read -r -p "Start Traefik now? [Y/n]: " answer
            answer="${answer:-y}"
        fi
        if [[ "$answer" =~ ^[Yy] ]]; then
            info "Starting Traefik"
            compose up -d
        fi
    fi

    echo
    echo "Done. Installation type: $INSTALL_TYPE"
    echo "Dashboard: https://${DASHBOARD_DOMAIN} (user: ${ADMIN_USER})"
    echo "Point the DNS record for ${DASHBOARD_DOMAIN} at this server so Let's Encrypt can issue the certificate."
}

main
