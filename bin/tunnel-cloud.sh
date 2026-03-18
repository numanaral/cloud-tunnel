#!/usr/bin/env bash
set -euo pipefail

# tunnel-cloud — Hassle-free CLI to expose local dev servers via
# Cloudflare Tunnels with stable subdomains.
#
# Platform: macOS, Linux (WSL on Windows).
# Requires: cloudflared (auto-installed if missing).

VERSION="0.1.1"
PROJECT_DIR="$(pwd)"
TUNNEL_DIR="$PROJECT_DIR/.tunnel"

# ── Formatting helpers ───────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "${CYAN}ℹ${NC} $*"; }
ok()    { echo -e "${GREEN}✔${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✖${NC} $*" >&2; }
die()   { err "$@"; exit 1; }
step()  { echo -e "${DIM}→${NC} $*" >&2; }

# ── Platform detection ───────────────────────────────────────────────

detect_platform() {
  local os
  os="$(uname -s)"
  case "$os" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    MINGW*|MSYS*|CYGWIN*)
      die "Windows is not supported. Use WSL (Windows Subsystem for Linux) instead." ;;
    *)
      die "Unsupported platform: $os" ;;
  esac
}

PLATFORM="$(detect_platform)"

# ── Argument parsing ─────────────────────────────────────────────────

COMMAND=""
ARG_DOMAIN=""
ARG_NAME=""
ARG_ORIGIN=""
ARG_PREFIX=""
ARG_PROTO=""
ARG_NO_WATCH=false

while [ $# -gt 0 ]; do
  case "$1" in
    start|stop|status|logs|cleanup|help)
      COMMAND="$1"; shift ;;
    --domain)
      [ $# -ge 2 ] || die "--domain requires a value."
      ARG_DOMAIN="$2"; shift 2 ;;
    --name)
      [ $# -ge 2 ] || die "--name requires a value."
      ARG_NAME="$2"; shift 2 ;;
    --origin)
      [ $# -ge 2 ] || die "--origin requires a value."
      ARG_ORIGIN="$2"; shift 2 ;;
    --prefix)
      [ $# -ge 2 ] || die "--prefix requires a value."
      ARG_PREFIX="$2"; shift 2 ;;
    --protocol)
      [ $# -ge 2 ] || die "--protocol requires a value."
      ARG_PROTO="$2"; shift 2 ;;
    --no-watch)
      ARG_NO_WATCH=true; shift ;;
    --version|-v) echo "tunnel-cloud $VERSION"; exit 0 ;;
    -*)
      die "Unknown option: $1. Run 'tunnel-cloud help' for usage." ;;
    *)
      die "Unknown argument: $1. Run 'tunnel-cloud help' for usage." ;;
  esac
done

COMMAND="${COMMAND:-help}"

# ── Config resolution (args > env vars > cached > defaults) ──────────

CONF_FILE="$TUNNEL_DIR/config"
PID_FILE="$TUNNEL_DIR/pid"
WATCHDOG_PID_FILE="$TUNNEL_DIR/watchdog-pid"
LOG_FILE="$TUNNEL_DIR/log"
YML_FILE="$TUNNEL_DIR/cloudflared.yml"

load_cached_config() {
  if [ -f "$CONF_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONF_FILE"
  fi
}

save_config() {
  mkdir -p "$TUNNEL_DIR"
  cat > "$CONF_FILE" <<EOF
CACHED_DOMAIN="$TUNNEL_DOMAIN"
CACHED_NAME="$TUNNEL_NAME"
CACHED_PREFIX="$TUNNEL_PREFIX"
CACHED_PROTO="$TUNNEL_PROTO"
EOF
}

load_cached_config

TUNNEL_DOMAIN="${ARG_DOMAIN:-${TUNNEL_DOMAIN:-${CACHED_DOMAIN:-}}}"
TUNNEL_NAME="${ARG_NAME:-${TUNNEL_NAME:-${CACHED_NAME:-$(basename "$PROJECT_DIR")}}}"
TUNNEL_ORIGIN="${ARG_ORIGIN:-${TUNNEL_ORIGIN:-}}"
TUNNEL_PREFIX="${ARG_PREFIX:-${TUNNEL_PREFIX:-${CACHED_PREFIX:-tunnel}}}"
TUNNEL_PROTO="${ARG_PROTO:-${TUNNEL_PROTO:-${CACHED_PROTO:-http2}}}"

# ── Validation helpers ───────────────────────────────────────────────

ensure_project_dir() {
  if [ ! -f "$PROJECT_DIR/package.json" ] && [ -z "$ARG_NAME" ]; then
    die "No package.json found in $(pwd)." \
      "\n  Either run from a project directory or provide --name explicitly." \
      "\n  Example: tunnel-cloud start --domain example.com --name my-app"
  fi
}

ensure_cloudflared() {
  if command -v cloudflared &>/dev/null; then
    return 0
  fi

  warn "cloudflared is not installed."
  echo ""

  local install_cmd=""
  case "$PLATFORM" in
    macos)
      if command -v brew &>/dev/null; then
        install_cmd="brew install cloudflared"
      else
        install_cmd="curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64.tgz | tar xz -C /usr/local/bin"
      fi
      ;;
    linux)
      if command -v apt-get &>/dev/null; then
        install_cmd="curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null && echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list && sudo apt-get update && sudo apt-get install -y cloudflared"
      elif command -v yum &>/dev/null; then
        install_cmd="sudo yum install -y cloudflared"
      else
        install_cmd="curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared"
      fi
      ;;
  esac

  echo -e "  Install command:"
  echo -e "  ${BOLD}$install_cmd${NC}"
  echo ""

  # Prompt for auto-install.
  read -rp "  Install now? [Y/n] " answer
  answer="${answer:-Y}"
  case "$answer" in
    [Yy]*)
      info "Installing cloudflared..."
      eval "$install_cmd"
      if ! command -v cloudflared &>/dev/null; then
        die "Installation failed. Please install cloudflared manually."
      fi
      ok "cloudflared installed ($(cloudflared --version 2>&1 | head -1))."
      ;;
    *)
      die "cloudflared is required. Install it and try again." ;;
  esac
}

ensure_logged_in() {
  if [ -f "$HOME/.cloudflared/cert.pem" ]; then
    return 0
  fi

  info "Not logged into Cloudflare. Opening browser for authentication..."
  echo -e "  ${DIM}Complete the login in your browser, then this script will continue.${NC}"
  echo ""
  cloudflared tunnel login
  echo ""

  if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
    die "Login failed — cert.pem not found after login."
  fi
  ok "Cloudflare login successful."
}

ensure_origin_reachable() {
  local origin="$1"
  local host port

  # Extract host:port from the origin URL.
  host=$(echo "$origin" | sed -E 's|https?://||; s|/.*||; s|:.*||')
  port=$(echo "$origin" | grep -oE ':[0-9]+' | tr -d ':' | head -1)
  port="${port:-80}"

  # Quick TCP check (nc works on both macOS and Linux, unlike /dev/tcp).
  if ! nc -z -w 2 "$host" "$port" 2>/dev/null; then
    err "Cannot reach origin at ${BOLD}$origin${NC}"
    echo ""
    echo "  Make sure your dev server is running first. For example:"
    echo -e "    ${DIM}yarn dev${NC}  or  ${DIM}npm run dev${NC}"
    echo ""

    if [ -z "$TUNNEL_ORIGIN" ]; then
      echo "  The origin was auto-detected. If this is wrong, specify it manually:"
      echo -e "    ${DIM}tunnel-cloud start --domain $TUNNEL_DOMAIN --origin http://localhost:<port>${NC}"
    fi

    exit 1
  fi
}

# ── Origin auto-detection ────────────────────────────────────────────
# Finds any TCP-listening process whose working directory matches this
# project. Works with Next.js, Vite, Express, Remix, Astro, Python,
# Go, Ruby, etc.
#
# Uses a single lsof call (cwd + TCP listeners) parsed with awk to
# avoid per-PID lsof calls which are ~3s each on macOS.

detect_origin() {
  if [ -n "$TUNNEL_ORIGIN" ]; then
    echo "$TUNNEL_ORIGIN"
    return
  fi

  local result
  result=$(lsof -d cwd -iTCP -sTCP:LISTEN -P -n -Fnc 2>/dev/null | awk -v dir="$PROJECT_DIR" '
    /^p/  { pid = substr($0, 2); cwd_match = 0; cmd = "" }
    /^c/  { cmd = substr($0, 2) }
    /^f/  { fd = substr($0, 2) }
    /^n/  {
            name = substr($0, 2)
            if (fd == "cwd" && name == dir) cwd_match = 1
            if (cwd_match && fd != "cwd" && name ~ /:[0-9]+$/) {
              if (cmd ~ /cursorsandbox|Electron|code-helper/) next
              n = split(name, parts, ":")
              port = parts[n]
              if (port + 0 > 0) { print pid " " port; exit }
            }
          }
  ')

  if [ -n "$result" ]; then
    local pid port cmd
    pid=$(echo "$result" | awk '{ print $1 }')
    port=$(echo "$result" | awk '{ print $2 }')
    cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
    step "Auto-detected server (PID $pid, port $port): ${cmd:0:60}"
    echo "http://localhost:$port"
    return
  fi

  err "No running server detected in this directory."
  echo ""
  echo "  Start your dev server first, or specify the origin manually:"
  echo -e "    ${DIM}tunnel-cloud start --domain ${TUNNEL_DOMAIN:-<domain>} --origin http://localhost:<port>${NC}"
  exit 1
}

# ── Cloudflared tunnel helpers ───────────────────────────────────────

ensure_tunnel_exists() {
  if cloudflared tunnel info "$TUNNEL_NAME" &>/dev/null; then
    return 0
  fi

  step "Creating tunnel '$TUNNEL_NAME'..."
  if ! cloudflared tunnel create "$TUNNEL_NAME"; then
    die "Failed to create tunnel '$TUNNEL_NAME'." \
      "\n  A tunnel with this name may already exist under a different account." \
      "\n  Try: cloudflared tunnel list"
  fi
  ok "Tunnel '$TUNNEL_NAME' created."
}

ensure_dns_route() {
  local hostname="$1"
  step "Ensuring DNS route $hostname -> tunnel '$TUNNEL_NAME'..."
  if ! cloudflared tunnel route dns --overwrite-dns "$TUNNEL_NAME" "$hostname" 2>&1; then
    warn "DNS route setup returned an error (may already exist, continuing)."
  fi
  ok "DNS route ready."
}

find_credentials() {
  local cred_file

  # First try: credentials newer than cert.pem (just-created tunnel).
  cred_file=$(find "$HOME/.cloudflared/" -name "*.json" -newer "$HOME/.cloudflared/cert.pem" 2>/dev/null | head -1)

  # Fallback: find by tunnel ID.
  if [ -z "$cred_file" ]; then
    local tunnel_id
    tunnel_id=$(cloudflared tunnel info "$TUNNEL_NAME" 2>&1 \
      | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
    if [ -n "$tunnel_id" ]; then
      cred_file="$HOME/.cloudflared/$tunnel_id.json"
    fi
  fi

  if [ -z "$cred_file" ] || [ ! -f "$cred_file" ]; then
    die "Could not locate tunnel credentials file." \
      "\n  Try: tunnel-cloud cleanup && tunnel-cloud start --domain $TUNNEL_DOMAIN"
  fi

  echo "$cred_file"
}

write_cloudflared_config() {
  local hostname="$1"
  local origin="$2"
  local cred_file="$3"

  mkdir -p "$TUNNEL_DIR"
  cat > "$YML_FILE" <<EOF
tunnel: $TUNNEL_NAME
credentials-file: $cred_file

ingress:
  - hostname: $hostname
    service: $origin
  - service: http_status:404
EOF
}

# ── Watchdog ──────────────────────────────────────────────────────────

start_cloudflared() {
  mkdir -p "$TUNNEL_DIR"
  cloudflared tunnel --config "$YML_FILE" --protocol "$TUNNEL_PROTO" run "$TUNNEL_NAME" > "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
}

# Quick tunnel: no account, no domain, no DNS — just a random trycloudflare.com URL.
start_quick_tunnel() {
  local origin="$1"
  mkdir -p "$TUNNEL_DIR"
  cloudflared tunnel --url "$origin" > "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
}

# Monitors the cloudflared process and restarts it on unexpected death.
# Gives up after MAX_RETRIES consecutive failures within RETRY_WINDOW seconds.
start_watchdog() {
  local max_retries=5
  local retry_window=60

  (
    local failures=0
    local window_start
    window_start=$(date +%s)

    while true; do
      sleep 5

      if [ ! -f "$PID_FILE" ]; then
        break
      fi

      local pid
      pid=$(cat "$PID_FILE" 2>/dev/null || true)
      if [ -z "$pid" ]; then
        break
      fi

      if kill -0 "$pid" 2>/dev/null; then
        failures=0
        window_start=$(date +%s)
        continue
      fi

      local now
      now=$(date +%s)
      if (( now - window_start > retry_window )); then
        failures=0
        window_start=$now
      fi

      failures=$((failures + 1))
      if (( failures > max_retries )); then
        echo -e "${RED}✖${NC} Tunnel crashed $max_retries times in ${retry_window}s — giving up." >&2
        rm -f "$PID_FILE" "$WATCHDOG_PID_FILE"
        break
      fi

      echo -e "${YELLOW}⚠${NC} Tunnel process died — restarting (attempt $failures/$max_retries)..." >&2
      start_cloudflared
    done
  ) &
  echo $! > "$WATCHDOG_PID_FILE"
}

stop_watchdog() {
  if [ -f "$WATCHDOG_PID_FILE" ]; then
    local wpid
    wpid=$(cat "$WATCHDOG_PID_FILE")
    if kill -0 "$wpid" 2>/dev/null; then
      kill "$wpid" 2>/dev/null || true
    fi
    rm -f "$WATCHDOG_PID_FILE"
  fi
}

# ── Commands ─────────────────────────────────────────────────────────

cmd_start() {
  ensure_project_dir

  local origin
  origin="$(detect_origin)"

  # Check if already running.
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    ok "Tunnel already running (PID $(cat "$PID_FILE"))"
    echo "  Stop: tunnel-cloud stop"
    exit 0
  fi

  # Validate origin is reachable.
  ensure_origin_reachable "$origin"

  if [ -z "$TUNNEL_DOMAIN" ]; then
    cmd_start_quick "$origin"
  else
    cmd_start_named "$origin"
  fi
}

# Quick tunnel: random *.trycloudflare.com URL, no account needed.
cmd_start_quick() {
  local origin="$1"

  info "No --domain provided — starting quick tunnel (random trycloudflare.com URL)..."
  echo -e "  ${DIM}For a stable subdomain on your own domain, use --domain${NC}"
  echo ""

  start_quick_tunnel "$origin"

  printf "  Waiting for URL"
  local url=""
  for _ in $(seq 1 20); do
    url=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_FILE" 2>/dev/null | head -1 || true)
    if [ -n "$url" ]; then
      break
    fi
    printf "."
    sleep 1
  done
  echo ""

  if [ -n "$url" ]; then
    echo ""
    ok "Tunnel is live!"
    echo -e "  URL:    ${BOLD}$url${NC}"
    echo "  Origin: $origin"
    echo "  PID:    $(cat "$PID_FILE")"
  else
    echo ""
    warn "Tunnel is starting (may take a few more seconds)..."
    echo "  Logs: tunnel-cloud logs"
  fi

  if ! $ARG_NO_WATCH; then
    start_watchdog
    echo ""
    echo "  Auto-restart: enabled (disable with --no-watch)"
  fi

  echo ""
  echo "  Stop with: tunnel-cloud stop"
}

# Named tunnel: stable subdomain on your own domain.
cmd_start_named() {
  local origin="$1"
  local hostname="$TUNNEL_PREFIX-$TUNNEL_NAME.$TUNNEL_DOMAIN"

  ensure_logged_in
  ensure_tunnel_exists
  ensure_dns_route "$hostname"
  save_config

  local cred_file
  cred_file="$(find_credentials)"
  write_cloudflared_config "$hostname" "$origin" "$cred_file"

  info "Starting tunnel..."
  start_cloudflared

  printf "  Waiting for connection"
  local connected=false
  for _ in $(seq 1 15); do
    if grep -qi "registered tunnel connection" "$LOG_FILE" 2>/dev/null; then
      connected=true
      break
    fi
    printf "."
    sleep 1
  done
  echo ""

  if $connected; then
    echo ""
    ok "Tunnel is live!"
    echo -e "  URL:    ${BOLD}https://$hostname${NC}"
    echo "  Origin: $origin"
    echo "  PID:    $(cat "$PID_FILE")"
  else
    echo ""
    warn "Tunnel is starting (may take a few more seconds)..."
    echo -e "  URL:  ${BOLD}https://$hostname${NC}"
    echo "  Logs: tunnel-cloud logs"
  fi

  if ! $ARG_NO_WATCH; then
    start_watchdog
    echo ""
    echo "  Auto-restart: enabled (disable with --no-watch)"
  fi

  echo ""
  echo "  Stop with: tunnel-cloud stop"
}

cmd_stop() {
  stop_watchdog

  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid"
      ok "Tunnel stopped (PID $pid)"
    else
      warn "Tunnel process already dead."
    fi
    rm -f "$PID_FILE"
  else
    info "No tunnel running."
  fi
  rm -f "$LOG_FILE" "$YML_FILE"
}

cmd_status() {
  load_cached_config
  local hostname="${TUNNEL_PREFIX:-tunnel}-${TUNNEL_NAME:-?}.${TUNNEL_DOMAIN:-?}"

  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    ok "Tunnel is running"
    echo "  PID:    $(cat "$PID_FILE")"
    echo -e "  URL:    ${BOLD}https://$hostname${NC}"

    if [ -f "$WATCHDOG_PID_FILE" ] && kill -0 "$(cat "$WATCHDOG_PID_FILE")" 2>/dev/null; then
      echo "  Watch:  enabled (PID $(cat "$WATCHDOG_PID_FILE"))"
    else
      echo "  Watch:  disabled"
    fi
  else
    info "Tunnel is not running."
    rm -f "$PID_FILE" "$WATCHDOG_PID_FILE"
  fi
}

cmd_logs() {
  if [ -f "$LOG_FILE" ]; then
    tail -f "$LOG_FILE"
  else
    die "No tunnel log found. Start a tunnel first: tunnel-cloud start --domain <domain>"
  fi
}

cmd_cleanup() {
  cmd_stop 2>/dev/null || true

  if [ -z "$TUNNEL_DOMAIN" ]; then
    die "--domain is required for cleanup (or cached config must exist)." \
      "\n  Example: tunnel-cloud cleanup --domain example.com"
  fi

  local hostname="$TUNNEL_PREFIX-$TUNNEL_NAME.$TUNNEL_DOMAIN"

  step "Removing DNS route for $hostname..."
  cloudflared tunnel route dns --overwrite-dns "$TUNNEL_NAME" "$hostname" 2>/dev/null || true

  step "Deleting tunnel '$TUNNEL_NAME'..."
  cloudflared tunnel delete -f "$TUNNEL_NAME" 2>/dev/null || true

  rm -rf "$TUNNEL_DIR"
  ok "Tunnel '$TUNNEL_NAME' fully cleaned up."
}

cmd_help() {
  local hostname="${TUNNEL_PREFIX:-tunnel}-${TUNNEL_NAME:-<name>}.${TUNNEL_DOMAIN:-<domain>}"

  cat <<EOF
tunnel-cloud $VERSION — Hassle-free CLI to expose local dev servers via Cloudflare Tunnels.

Usage: tunnel-cloud <command> [options]

Commands:
  start     Create tunnel (if needed) and start serving
  stop      Stop the running tunnel
  status    Check if the tunnel is running
  logs      Tail the tunnel log
  cleanup   Stop, delete tunnel and DNS route entirely

Options:
  --domain <domain>     Cloudflare domain (omit for a random trycloudflare.com URL)
  --name <name>         Tunnel name (default: directory name)
  --origin <url>        Local URL (default: auto-detect from running server)
  --prefix <prefix>     Subdomain prefix (default: tunnel)
  --protocol <proto>    cloudflared protocol (default: http2)
  --no-watch            Disable auto-restart on tunnel process death
  --version, -v         Print version

Environment variables (override options):
  TUNNEL_DOMAIN, TUNNEL_NAME, TUNNEL_ORIGIN, TUNNEL_PREFIX, TUNNEL_PROTO

Platform: macOS, Linux (WSL on Windows)
Prerequisites: cloudflared (auto-installed if missing)

Current config:
  Name:     ${TUNNEL_NAME:-<not set>}
  Domain:   ${TUNNEL_DOMAIN:-<not set>}
  Prefix:   ${TUNNEL_PREFIX:-tunnel}
  Hostname: $hostname

Examples:
  tunnel-cloud start                                          # quick tunnel (random URL)
  tunnel-cloud start --domain numanaral.dev                   # stable subdomain
  tunnel-cloud start --domain numanaral.dev --name my-app --origin http://localhost:4000
  tunnel-cloud start --domain numanaral.dev --prefix staging
  tunnel-cloud stop
  tunnel-cloud cleanup
EOF
}

# ── Main ─────────────────────────────────────────────────────────────

ensure_cloudflared

case "$COMMAND" in
  start)   cmd_start   ;;
  stop)    cmd_stop    ;;
  status)  cmd_status  ;;
  logs)    cmd_logs    ;;
  cleanup) cmd_cleanup ;;
  help)    cmd_help    ;;
esac
