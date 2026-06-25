#!/usr/bin/env bash
#
# RCV NOC Portal — installer.
#
# The Portal is the floor of the RCV platform: install it first, then add modules
# from the Portal UI (Modules → Install) or by registering each module's
# rcv-module.json. This script generates strong secrets into .env (never
# overwriting values you've already set), brings up the Portal, waits for it to
# be healthy, and prints the login URL.
#
# Usage:
#   ./install.sh             # generate .env (with random secrets) and start
#   ./install.sh --no-start  # only generate/refresh .env, don't start Docker
#   ./install.sh --help
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
EXAMPLE_FILE="$SCRIPT_DIR/.env.example"

START=1
if [ "${1:-}" != "add-module" ]; then
  for arg in "$@"; do
    case "$arg" in
      --no-start) START=0 ;;
      -h | --help)
        sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
      *)
        echo "Unknown option: $arg (try --help)" >&2
        exit 2
        ;;
    esac
  done
fi

# --- secret generators (openssl preferred, python fallback) ----------------

gen_hex() {
  local nbytes="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$nbytes"
  else
    python3 -c "import secrets,sys;print(secrets.token_hex(int(sys.argv[1])))" "$nbytes"
  fi
}

gen_fernet_key() {
  # A urlsafe-base64 32-byte key, the format Fernet expects.
  if python3 -c "from cryptography.fernet import Fernet" >/dev/null 2>&1; then
    python3 -c "from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())"
  else
    openssl rand -base64 32 | tr '+/' '-_'
  fi
}

gen_password() {
  # A short random admin password printed once at install (issue #108). The UI
  # forces a rotation at first login, so this only has to survive the first
  # sign-in — it must never be the static `changeme` on disk. Strip + / = so the
  # value is safe in .env and easy to copy-paste.
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 18 | tr '+/' '-_' | tr -d '='
  else
    python3 -c "import secrets;print(secrets.token_urlsafe(18))"
  fi
}

# --- .env templating -------------------------------------------------------

current_value() {
  # Echo the current value of KEY in .env (empty if absent/blank).
  local key="$1"
  sed -n "s/^${key}=//p" "$ENV_FILE" | head -n1
}

set_value() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    # Replace in place (| delimiter avoids clashes with / and + in secrets).
    sed -i.bak "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    rm -f "$ENV_FILE.bak"
  else
    printf '%s=%s\n' "$key" "$val" >>"$ENV_FILE"
  fi
}

# fill_secret KEY GENERATOR [PLACEHOLDER...]
# Sets KEY to a freshly generated value only when it is empty or still equal to a
# known placeholder — so re-running the installer is idempotent and never clobbers
# an operator-chosen secret.
fill_secret() {
  local key="$1" gen="$2"
  shift 2
  local cur
  cur="$(current_value "$key")"
  if [ -n "$cur" ]; then
    for placeholder in "$@"; do
      if [ "$cur" = "$placeholder" ]; then
        set_value "$key" "$("$gen")"
        return 0
      fi
    done
    return 0 # already customized — leave it
  fi
  set_value "$key" "$("$gen")"
}

honor_env_vars() {
  # If the operator passed vars in the environment (e.g. PORTAL_PUBLIC_BASE_URL=http://host ./install.sh),
  # inject them into .env BEFORE fill_secret runs -- so they are preserved (#2).
  local honored=(
    PORTAL_PUBLIC_BASE_URL
    PORTAL_REQUIRE_HTTPS
    PORTAL_DEFAULT_ADMIN_EMAIL
    PORTAL_DEFAULT_ADMIN_PASSWORD
    PORTAL_ORCHESTRATOR
    PORTAL_ENVIRONMENT
    LOG_LEVEL
  )
  local key
  for key in "${honored[@]}"; do
    local val="${!key:-}"
    if [ -n "$val" ]; then
      set_value "$key" "$val"
    fi
  done
}

ensure_env() {
  if [ ! -f "$ENV_FILE" ]; then
    cp "$EXAMPLE_FILE" "$ENV_FILE"
    echo "Created .env from .env.example"
  fi
  honor_env_vars   # inject shell env vars into .env before fill_secret runs (#2)
  fill_secret PORTAL_SECRET_KEY "gen_hex"
  fill_secret POSTGRES_PASSWORD "gen_hex" "portal"
  fill_secret PORTAL_SECRETS_ENCRYPTION_KEY "gen_fernet_key"
  # Replace the `changeme` placeholder admin password with a random one so the
  # default credential is never persisted (issue #108). print_next_steps echoes
  # the generated value once; first login forces a rotation.
  fill_secret PORTAL_DEFAULT_ADMIN_PASSWORD "gen_password" "changeme"
  echo "Secrets ensured in .env (existing values preserved)."

  # HTTPS posture check (issue #117). ----------------------------------------
  # The default install posture is HTTPS (PORTAL_REQUIRE_HTTPS=true). Warn the
  # operator if the base URL is still the example placeholder so they know to
  # update it before SSO/OIDC will work in production. Dev/LAN installs that
  # deliberately set PORTAL_REQUIRE_HTTPS=false are left alone — the server
  # logs its own "INSECURE: SSO over HTTP" warning at startup.
  local require_https_val base_url_val
  require_https_val="$(current_value PORTAL_REQUIRE_HTTPS)"
  base_url_val="$(current_value PORTAL_PUBLIC_BASE_URL)"
  if [ "${require_https_val:-true}" = "true" ]; then
    case "$base_url_val" in
      "https://noc.example.com" | "")
        echo "NOTE: PORTAL_PUBLIC_BASE_URL is still the placeholder (${base_url_val:-unset})."
        echo "  Update it to your real https:// gateway URL (e.g. https://noc.myorg.com)"
        echo "  before SSO/OIDC redirect URIs and the OIDC issuer will work correctly."
        echo "  For a local/LAN dev install over plain HTTP, set:"
        echo "    PORTAL_REQUIRE_HTTPS=false"
        echo "    PORTAL_PUBLIC_BASE_URL=http://<your-host>"
        ;;
      http://*)
        echo "WARNING: PORTAL_REQUIRE_HTTPS=true but PORTAL_PUBLIC_BASE_URL is an"
        echo "  http:// URL (${base_url_val}). The OIDC issuer will advertise an insecure"
        echo "  URL. Either set PORTAL_PUBLIC_BASE_URL to an https:// URL, or set"
        echo "  PORTAL_REQUIRE_HTTPS=false for a deliberate dev/LAN install."
        ;;
    esac
  else
    echo "INSECURE: PORTAL_REQUIRE_HTTPS=false — SSO/OIDC tokens travel in"
    echo "  cleartext. Acceptable for local dev / trusted LAN only."
  fi

  # Auto-enable one-click module deploys (issue #51). install.sh IS the
  # single-host Docker installer, so the environment is "compose" by
  # definition — detect it instead of making the operator hand-set
  # PORTAL_ORCHESTRATOR and start a profile. Only promote the default 'none';
  # never clobber an operator who deliberately chose another value.
  local orch
  orch="$(current_value PORTAL_ORCHESTRATOR)"
  if [ -z "$orch" ] || [ "$orch" = "none" ]; then
    if compose version >/dev/null 2>&1; then
      set_value PORTAL_ORCHESTRATOR "compose"
      echo "Detected Docker Compose → PORTAL_ORCHESTRATOR=compose (one-click deploy on)."
    fi
  fi
  # The deployer sidecar refuses every request until this token is set, so the
  # compose orchestrator needs it. Generate one if empty.
  fill_secret PORTAL_DEPLOYER_TOKEN "gen_hex"

  ensure_registry_creds
}

# Module images live in private GHCR packages. The deployer sidecar runs
# `docker compose up` in its *own* container, which resolves registry auth from
# its own docker config — not the host's — so docker-compose.yml mounts the
# host's config dir into it (read-only). Record where that config lives and warn
# if no usable ghcr.io login is present, since a private pull would otherwise
# fail with a bare "denied". Only relevant when the compose orchestrator is on.
ensure_registry_creds() {
  [ "$(current_value PORTAL_ORCHESTRATOR)" = "compose" ] || return 0
  local cfgdir cfg
  cfgdir="${DOCKER_CONFIG:-$HOME/.docker}"
  cfg="$cfgdir/config.json"
  set_value PORTAL_DOCKER_CONFIG_DIR "$cfgdir"
  if [ ! -f "$cfg" ]; then
    echo "No docker registry login found ($cfg missing). To deploy private module"
    echo "  images, log in once on this host:  docker login ghcr.io"
  elif grep -q '"credsStore"\|"credHelpers"' "$cfg" 2>/dev/null; then
    echo "Note: $cfg uses a credential helper, so the deployer can't read your login."
    echo "  If a module Deploy fails with 'denied', run:  docker login ghcr.io"
    echo "  (without a helper it stores the token directly where the deployer can use it)."
  elif grep -q 'ghcr.io' "$cfg" 2>/dev/null; then
    echo "Registry login detected in $cfg → deployer can pull private module images."
  else
    echo "No ghcr.io entry in $cfg. To deploy private module images, run:"
    echo "  docker login ghcr.io"
  fi
}

# Echo the compose profile flag to start the deployer sidecar — only when the
# resolved orchestrator is 'compose', so the Deploy button actually works.
deploy_profile_args() {
  if [ "$(current_value PORTAL_ORCHESTRATOR)" = "compose" ]; then
    printf '%s' "--profile deploy"
  fi
}

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

wait_for_health() {
  # The gateway (Caddy) serves HTTPS :443 with a self-signed `tls internal` cert
  # and plain HTTP :80 (LAN-friendly; cookies are marked Secure per-request from
  # X-Forwarded-Proto). Try HTTPS first, then HTTP; follow redirects (-L) and
  # accept the internal cert (-k) for public configs that force HTTPS.
  echo -n "Waiting for the Portal to be healthy"
  local url
  for _ in $(seq 1 60); do
    for url in "https://localhost/health" "http://localhost/health"; do
      if curl -fsSk -L "$url" >/dev/null 2>&1; then
        echo " — ok"
        return 0
      fi
    done
    echo -n "."
    sleep 2
  done
  echo
  echo "Portal did not become healthy in time. Check: docker compose logs web" >&2
  return 1
}

# print_next_steps [healthy]: always prints the access URL + default creds, even
# if the health check timed out (the operator still needs this information).
print_next_steps() {
  local healthy="${1:-1}" admin_email admin_pass public_base host_ip
  admin_email="$(current_value PORTAL_DEFAULT_ADMIN_EMAIL)"
  [ -z "$admin_email" ] && admin_email="admin@rcv.example.com"
  admin_pass="$(current_value PORTAL_DEFAULT_ADMIN_PASSWORD)"
  [ -z "$admin_pass" ] && admin_pass="changeme"
  public_base="$(current_value PORTAL_PUBLIC_BASE_URL)"
  # Ignore placeholder / default values; only show a non-placeholder public URL.
  case "$public_base" in
    "" | "http://localhost:8000" | "https://noc.example.com") public_base="" ;;
  esac
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || host_ip=""

  echo
  echo "============================================================"
  if [ "$healthy" -eq 0 ]; then
    echo "  RCV NOC Portal started, but the health check timed out."
    echo "  If the page doesn't load shortly: docker compose logs web"
    echo "  ----------------------------------------------------------"
  else
    echo "  RCV NOC Portal is up."
  fi
  echo
  echo "  Open:     https://localhost/         (on this host)"
  [ -n "$host_ip" ] && echo "            https://$host_ip/         (from your network)"
  echo "            Gateway uses a self-signed cert (tls internal): accept the"
  echo "            browser warning once. HTTP :80 redirects to HTTPS :443."
  [ -n "$public_base" ] && echo "  Public:   $public_base"
  echo
  echo "  Sign in:  $admin_email"
  echo "  Password: $admin_pass"
  echo "            ^ rotate this password immediately at first login."
  echo
  echo "  Next: add modules — Portal → Modules → Install. See HANDOFF.md."
  echo "============================================================"
}

# add-module <id> [--print]: scaffold a docker-compose override that runs a
# module's published image on the Portal's external rcv-net, with its own DB.
add_module() {
  local id="${1:-}"
  local do_print=0
  shift || true
  for a in "$@"; do
    case "$a" in
      --print) do_print=1 ;;
      *) echo "Unknown option: $a" >&2; exit 2 ;;
    esac
  done

  local image port dbimage
  case "$id" in
    pingit) image=pingit-web; port=8000; dbimage="timescale/timescaledb:latest-pg16" ;;
    site-look-up) image=site-look-up; port=3000; dbimage="postgres:16-alpine" ;;
    outage-track) image=outage-track; port=3000; dbimage="postgres:16-alpine" ;;
    "")
      echo "usage: install.sh add-module <pingit|site-look-up|outage-track> [--print]" >&2
      exit 2
      ;;
    *)
      echo "Unknown module: $id (pingit | site-look-up | outage-track)" >&2
      exit 2
      ;;
  esac

  local owner="${RCV_GHCR_OWNER:-root-chain-ventures-llc}"
  local content
  content="$(
    cat <<YAML
# Generated by install.sh add-module $id. Run alongside the Portal:
#   docker compose -f $id.compose.yml up -d
# Joins the Portal's external rcv-net; the gateway routes /$id to ${id}-web:$port.
# Set the module's other env (OIDC client secret, NEXTAUTH_SECRET / JWT_SECRET,
# etc.) from its repo's .env.example before bringing it up.
name: rcv-$id
services:
  $id-web:
    image: ghcr.io/$owner/$image:latest
    restart: unless-stopped
    depends_on:
      $id-db:
        condition: service_healthy
    environment:
      PORTAL_URL: \${PORTAL_URL:-http://web:8000}
      PORTAL_API_KEY: \${PORTAL_API_KEY:?mint a platform key in the Portal (API Keys)}
    networks: [rcv-net]
  $id-db:
    image: $dbimage
    restart: unless-stopped
    environment:
      POSTGRES_USER: $id
      POSTGRES_PASSWORD: \${MODULE_DB_PASSWORD:-$id}
      POSTGRES_DB: $id
    volumes:
      - $id-pgdata:/var/lib/postgresql/data
    networks: [rcv-net]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $id -d $id"]
      interval: 5s
      timeout: 5s
      retries: 10
networks:
  rcv-net:
    external: true
volumes:
  $id-pgdata:
YAML
  )"

  if [ "$do_print" -eq 1 ]; then
    printf '%s\n' "$content"
    return 0
  fi
  printf '%s\n' "$content" >"$SCRIPT_DIR/$id.compose.yml"
  echo "Wrote $id.compose.yml."
  echo "Next: register '$id' in the Portal (Modules → Install, or POST"
  echo "/api/platform/modules) to mint its OIDC client, set PORTAL_API_KEY, then:"
  echo "  docker compose -f $id.compose.yml up -d"
}

main() {
  ensure_env
  if [ "$START" -eq 0 ]; then
    echo ".env ready. Skipping start (--no-start)."
    exit 0
  fi
  # Build from local source only when the dev override + source tree are present
  # (a full repo clone). A clean public install bundle ships just the base
  # compose, which PULLS the published images instead (issue #104 / #107).
  local build_files=() build_flag=""
  if [ -f "$SCRIPT_DIR/docker-compose.build.yml" ] && [ -d "$SCRIPT_DIR/backend" ]; then
    build_files=(-f docker-compose.yml -f docker-compose.build.yml)
    build_flag="--build"
    echo "Starting the Portal (docker compose up -d --build, from local source)…"
  else
    echo "Starting the Portal (docker compose up -d, pulling published images)…"
  fi
  # shellcheck disable=SC2046 # intentional word-splitting of the profile flag
  (cd "$SCRIPT_DIR" && compose "${build_files[@]}" $(deploy_profile_args) up -d $build_flag)
  # Print the access URL + credentials whether or not the health probe passed —
  # an aborted banner is why operators couldn't find the login (issue follow-up).
  if wait_for_health; then
    print_next_steps 1
  else
    print_next_steps 0
  fi
}

# Only dispatch when executed directly; sourcing (e.g. tests) just loads the
# functions.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    add-module)
      shift
      add_module "$@"
      ;;
    *)
      main
      ;;
  esac
fi
