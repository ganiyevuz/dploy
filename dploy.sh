#!/bin/bash
# === dploy — Frontend Deployment CLI ===
#
# Global CLI tool for deploying frontend builds to a remote server.
#
# Install:
#   dploy install         — installs this script to /usr/local/bin/dploy
#
# Usage (run from any frontend project root):
#   dploy                 — detect dist folder, confirm, deploy
#   dploy build           — build first, then deploy
#   dploy rollback        — rollback to previous version on server
#   dploy init            — create a .env template in current directory
#   dploy status          — check server connection and current deployment
#
# Requires .env in project root with:
#   SERVER=root@your-server-ip
#   DEPLOY_DIR=/var/www/myapp/frontend
#   SSH_KEY=~/.ssh/id_rsa            (optional, auto-detects default key)
#   BUILD_CMD=npm run build          (optional, default: npm run build)
#
set -euo pipefail

VERSION="1.0.0"
SCRIPT_NAME="dploy"
INSTALL_PATH="/usr/local/bin/$SCRIPT_NAME"
ENV_FILE=".env"
ARCHIVE_NAME=""

# --- Colors (disabled if not a terminal) ---
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' NC=''
fi

log()  { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
err()  { echo -e "${RED}✗${NC} $1"; exit 1; }
info() { echo -e "${CYAN}→${NC} $1"; }

# --- Cleanup on exit ---
cleanup() {
    [[ -n "$ARCHIVE_NAME" && -f "$ARCHIVE_NAME" ]] && rm -f "$ARCHIVE_NAME"
}
trap cleanup EXIT

# --- Detect build/dist folder ---
detect_dist() {
    local candidates=("dist" "build" "out" ".next")
    for dir in "${candidates[@]}"; do
        if [[ -d "$dir" ]] && find "$dir" -maxdepth 1 -type f | read -r; then
            echo "$dir"
            return 0
        fi
    done
    return 1
}

# --- Load .env (safe: only KEY=VALUE lines) ---
load_env() {
    [[ -f "$ENV_FILE" ]] || err "No .env found in $(pwd)
  Run: ${BOLD}dploy init${NC} to create one"

    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        # Strip surrounding whitespace and quotes
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        value="${value%\"}" && value="${value#\"}"
        value="${value%\'}" && value="${value#\'}"
        export "$key=$value"
    done < "$ENV_FILE"

    [[ -n "${SERVER:-}" ]] || err "SERVER is not set in .env"
    [[ -n "${DEPLOY_DIR:-}" ]] || err "DEPLOY_DIR is not set in .env"

    # Resolve SSH key: use provided or find default
    if [[ -n "${SSH_KEY:-}" ]]; then
        SSH_KEY="${SSH_KEY/#\~/$HOME}"
        [[ -f "$SSH_KEY" ]] || err "SSH key not found: $SSH_KEY"
    else
        # Auto-detect default key
        for key in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
            if [[ -f "$key" ]]; then
                SSH_KEY="$key"
                break
            fi
        done
        [[ -n "$SSH_KEY" ]] || err "No SSH key found. Set SSH_KEY in .env or create one: ssh-keygen"
    fi

    # Validate DEPLOY_DIR is absolute path
    [[ "$DEPLOY_DIR" == /* ]] || err "DEPLOY_DIR must be an absolute path (starts with /)"

    # Build SSH/SCP options array
    SSH_OPTS=(-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "$SSH_KEY")

    BUILD_CMD="${BUILD_CMD:-npm run build}"
}

# --- Check SSH connectivity ---
check_ssh() {
    info "Checking SSH connection to ${BOLD}$SERVER${NC} ..."
    if ! ssh "${SSH_OPTS[@]}" "$SERVER" "echo ok" &>/dev/null; then
        err "Cannot connect to $SERVER
  Check: SSH_KEY=$SSH_KEY, server address, and firewall"
    fi
}

# --- Confirm prompt ---
confirm() {
    local dist_dir="$1"
    local action="${2:-Deploy}"
    local file_count dir_size

    file_count=$(find "$dist_dir" -type f | wc -l | tr -d ' ')
    dir_size=$(du -sh "$dist_dir" | cut -f1 | tr -d ' ')

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║          ${action^^} CONFIRMATION              ║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║${NC} Project : ${CYAN}$(basename "$(pwd)")${NC}"
    echo -e "${BOLD}║${NC} Folder  : ${CYAN}$dist_dir/${NC} ${DIM}($file_count files, $dir_size)${NC}"
    echo -e "${BOLD}║${NC} Server  : ${CYAN}$SERVER${NC}"
    echo -e "${BOLD}║${NC} SSH Key : ${CYAN}$SSH_KEY${NC}"
    echo -e "${BOLD}║${NC} Remote  : ${CYAN}$DEPLOY_DIR${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
    echo ""

    # Skip prompt if -y flag is set
    if [[ "${SKIP_CONFIRM:-}" == "1" ]]; then
        log "Auto-confirmed (-y flag)"
        return 0
    fi

    read -rp "$(echo -e "${YELLOW}Proceed? [y/N]:${NC} ")" answer
    [[ "$answer" =~ ^[Yy]$ ]] || { warn "Cancelled."; exit 0; }
}

# --- Confirm rollback ---
confirm_rollback() {
    echo ""
    warn "This will replace current deployment with the previous backup."
    echo -e "  Server: ${CYAN}$SERVER${NC}"
    echo -e "  Path:   ${CYAN}$DEPLOY_DIR${NC}"
    echo ""

    if [[ "${SKIP_CONFIRM:-}" == "1" ]]; then
        log "Auto-confirmed (-y flag)"
        return 0
    fi

    read -rp "$(echo -e "${YELLOW}Rollback now? [y/N]:${NC} ")" answer
    [[ "$answer" =~ ^[Yy]$ ]] || { warn "Cancelled."; exit 0; }
}

# ============================================================
# Parse flags
# ============================================================
SKIP_CONFIRM=0
POSITIONAL=()

for arg in "$@"; do
    case "$arg" in
        -y|--yes) SKIP_CONFIRM=1 ;;
        *)        POSITIONAL+=("$arg") ;;
    esac
done

CMD="${POSITIONAL[0]:-deploy}"

# ============================================================
# COMMANDS
# ============================================================

case "$CMD" in

    # --- Install globally ---
    install)
        SCRIPT_REAL=$(realpath "$0")
        INSTALL_REAL=$(realpath "$INSTALL_PATH" 2>/dev/null || echo "")

        if [[ "$SCRIPT_REAL" == "$INSTALL_REAL" ]]; then
            log "Already installed at $INSTALL_PATH (v$VERSION)"
            exit 0
        fi

        info "Installing to $INSTALL_PATH ..."
        sudo cp "$0" "$INSTALL_PATH"
        sudo chmod +x "$INSTALL_PATH"
        log "Installed ${BOLD}dploy${NC} v$VERSION globally."
        ;;

    # --- Init .env template ---
    init)
        if [[ -f "$ENV_FILE" ]]; then
            warn ".env already exists:"
            echo -e "${DIM}$(cat "$ENV_FILE")${NC}"
            exit 0
        fi
        cat > "$ENV_FILE" <<'TEMPLATE'
# dploy configuration
SERVER=root@your-server-ip
DEPLOY_DIR=/var/www/myapp/frontend
# SSH_KEY=~/.ssh/id_rsa            (optional, auto-detects default key)
# BUILD_CMD=npm run build
TEMPLATE
        log "Created .env — edit it with your server details."
        ;;

    # --- Build + Deploy ---
    build)
        load_env

        info "Building with: ${BOLD}$BUILD_CMD${NC}"
        if ! bash -c "$BUILD_CMD"; then
            err "Build failed!"
        fi
        log "Build complete."

        # Re-run as deploy (pass flags through)
        [[ "$SKIP_CONFIRM" == "1" ]] && exec "$0" -y deploy || exec "$0" deploy
        ;;

    # --- Deploy ---
    deploy)
        load_env

        DIST_DIR=$(detect_dist) || err "No build folder found!
  Checked: dist/, build/, out/, .next/
  Run your build command first: ${BOLD}$BUILD_CMD${NC}"

        confirm "$DIST_DIR"
        check_ssh

        ARCHIVE_NAME="dploy_$(date +%s).tar.gz"

        info "Archiving ${BOLD}$DIST_DIR/${NC} ..."
        tar -czf "$ARCHIVE_NAME" -C "$DIST_DIR" .
        SIZE=$(du -h "$ARCHIVE_NAME" | cut -f1 | tr -d ' ')
        log "Archive ready (${SIZE})"

        info "Uploading to ${BOLD}$SERVER${NC} ..."
        scp -q "${SSH_OPTS[@]}" "$ARCHIVE_NAME" "$SERVER:/tmp/$ARCHIVE_NAME"
        log "Upload complete."

        info "Deploying on server..."
        RESULT=$(ssh "${SSH_OPTS[@]}" "$SERVER" bash -s "$DEPLOY_DIR" "$ARCHIVE_NAME" <<'REMOTE'
set -euo pipefail
DEPLOY_DIR="$1"
ARCHIVE="/tmp/$2"

mkdir -p "$DEPLOY_DIR"

# Backup current version (only if non-empty)
if [[ -d "$DEPLOY_DIR" ]] && find "$DEPLOY_DIR" -maxdepth 1 -type f | read -r; then
    BACKUP="${DEPLOY_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
    cp -r "$DEPLOY_DIR" "$BACKUP"
    # Keep last 3 backups
    ls -dt "${DEPLOY_DIR}_backup_"* 2>/dev/null | tail -n +4 | xargs rm -rf 2>/dev/null || true
fi

# Extract new files
rm -rf "${DEPLOY_DIR:?}"/*
tar -xzf "$ARCHIVE" -C "$DEPLOY_DIR"
rm -f "$ARCHIVE"

FILE_COUNT=$(find "$DEPLOY_DIR" -type f | wc -l | tr -d ' ')
echo "OK:$FILE_COUNT"
REMOTE
        )

        if [[ "$RESULT" == OK:* ]]; then
            log "Deployed ${BOLD}${RESULT#OK:}${NC} files to ${BOLD}$SERVER:$DEPLOY_DIR${NC}"
        else
            err "Deploy failed on server!
  $RESULT"
        fi
        ;;

    # --- Rollback ---
    rollback)
        load_env
        confirm_rollback
        check_ssh

        info "Rolling back on ${BOLD}$SERVER${NC} ..."

        RESULT=$(ssh "${SSH_OPTS[@]}" "$SERVER" bash -s "$DEPLOY_DIR" <<'ROLLBACK'
set -euo pipefail
DEPLOY_DIR="$1"
LATEST_BACKUP=$(ls -dt "${DEPLOY_DIR}_backup_"* 2>/dev/null | head -1)

if [[ -z "$LATEST_BACKUP" ]]; then
    echo "FAIL:No backup found on server"
    exit 1
fi

rm -rf "${DEPLOY_DIR:?}"/*
cp -r "$LATEST_BACKUP"/* "$DEPLOY_DIR"/
rm -rf "$LATEST_BACKUP"

REMAINING=$(ls -d "${DEPLOY_DIR}_backup_"* 2>/dev/null | wc -l | tr -d ' ')
echo "OK:$(basename "$LATEST_BACKUP"):$REMAINING"
ROLLBACK
        )

        if [[ "$RESULT" == OK:* ]]; then
            IFS=':' read -r _ BACKUP_NAME REMAINING <<< "$RESULT"
            log "Rolled back to: ${BOLD}$BACKUP_NAME${NC}"
            [[ "$REMAINING" -gt 0 ]] && info "$REMAINING backup(s) remaining" || warn "No more backups available"
        else
            err "Rollback failed: ${RESULT#FAIL:}"
        fi
        ;;

    # --- Status ---
    status)
        load_env
        check_ssh

        info "Checking deployment at ${BOLD}$SERVER:$DEPLOY_DIR${NC} ..."

        ssh "${SSH_OPTS[@]}" "$SERVER" bash -s "$DEPLOY_DIR" <<'STATUS'
set -euo pipefail
D="$1"

if [[ ! -d "$D" ]]; then
    echo "  Status: NOT DEPLOYED"
    exit 0
fi

FILE_COUNT=$(find "$D" -type f | wc -l | tr -d ' ')
DIR_SIZE=$(du -sh "$D" | cut -f1 | tr -d ' ')
MODIFIED=$(stat -c '%Y' "$D" 2>/dev/null || stat -f '%m' "$D" 2>/dev/null)
MODIFIED_DATE=$(date -d "@$MODIFIED" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$MODIFIED" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")

BACKUPS=$(ls -d "${D}_backup_"* 2>/dev/null | wc -l | tr -d ' ')

echo "  Files:    $FILE_COUNT"
echo "  Size:     $DIR_SIZE"
echo "  Modified: $MODIFIED_DATE"
echo "  Backups:  $BACKUPS"
STATUS
        ;;

    # --- Version ---
    -v|--version|version)
        echo "dploy v$VERSION"
        ;;

    # --- Help ---
    -h|--help|help)
        echo -e "${BOLD}dploy${NC} v$VERSION — Frontend deployment CLI"
        echo ""
        echo -e "${BOLD}Commands:${NC}"
        echo "  dploy               Deploy detected build folder to server"
        echo "  dploy build         Build first, then deploy"
        echo "  dploy rollback      Rollback to previous version"
        echo "  dploy status        Check current deployment on server"
        echo "  dploy init          Create .env template in current dir"
        echo "  dploy install       Install globally to /usr/local/bin"
        echo ""
        echo -e "${BOLD}Flags:${NC}"
        echo "  -y, --yes           Skip confirmation prompts"
        echo ""
        echo -e "${BOLD}Config (.env):${NC}"
        echo "  SERVER              SSH target (e.g. root@192.168.1.10)"
        echo "  DEPLOY_DIR          Absolute path on server (e.g. /var/www/app)"
        echo "  SSH_KEY             SSH private key (default: auto-detect)"
        echo "  BUILD_CMD           Build command (default: npm run build)"
        echo ""
        echo -e "${BOLD}Auto-detected build folders:${NC} dist/, build/, out/, .next/"
        ;;

    # --- Unknown command ---
    *)
        err "Unknown command: $CMD
  Run ${BOLD}dploy help${NC} for usage"
        ;;
esac