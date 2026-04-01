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
#   dploy logs            — show deploy history on server
#   dploy ssh             — SSH into the server
#   dploy status          — check server connection and current deployment
#   dploy doctor          — run all checks (SSH, key, permissions, disk)
#   dploy update          — update dploy to latest version
#   dploy init            — create config templates (.env, .env.example, .dployignore)
#   dploy uninstall       — remove dploy from system
#
# Requires .env in project root with:
#   SERVER=root@your-server-ip
#   DEPLOY_DIR=/var/www/myapp/frontend
#   SSH_KEY=~/.ssh/id_rsa            (optional, auto-detects default key)
#   SSH_PORT=22                      (optional, default: 22)
#   BUILD_CMD=npm run build          (optional, default: npm run build)
#   POST_DEPLOY_CMD=                 (optional, runs on server after deploy)
#
set -euo pipefail

VERSION="1.2.1"
SCRIPT_NAME="dploy"
INSTALL_PATH="/usr/local/bin/$SCRIPT_NAME"
REPO="ganiyevuz/dploy"
REPO_RAW="https://raw.githubusercontent.com/$REPO/main"
ENV_FILE=".env"
IGNORE_FILE=".dployignore"
ARCHIVE_NAME=""
UPDATE_CHECK_FILE="$HOME/.dploy_last_check"
DEPLOY_START=""

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

log()  { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
err()  { echo -e "  ${RED}✗${NC} $1"; exit 1; }
info() { echo -e "  ${CYAN}▸${NC} $1"; }
step() { echo -e "\n  ${CYAN}[$1/$2]${NC} ${BOLD}$3${NC}"; }

# --- Header ---
header() {
    echo ""
    echo -e "  ${BOLD}${CYAN}dploy${NC} ${DIM}v$VERSION${NC}"
    echo -e "  ${DIM}─────────────────────────────────${NC}"
    echo ""
}

# --- Timer ---
timer_start() { DEPLOY_START=$(date +%s); }
timer_elapsed() {
    local elapsed=$(( $(date +%s) - DEPLOY_START ))
    if (( elapsed >= 60 )); then
        echo "$(( elapsed / 60 ))m $(( elapsed % 60 ))s"
    else
        echo "${elapsed}s"
    fi
}

# --- Cleanup on exit ---
cleanup() {
    [[ -n "$ARCHIVE_NAME" && -f "$ARCHIVE_NAME" ]] && rm -f "$ARCHIVE_NAME"
}
trap cleanup EXIT

# --- Handle Ctrl+C gracefully ---
cancel() {
    printf '\033[?25h' 2>/dev/null  # Restore cursor if hidden
    echo ""
    warn "Cancelled."
    exit 130
}
trap cancel INT TERM

# --- Check for updates (once per day, non-blocking) ---
check_update() {
    if [[ -f "$UPDATE_CHECK_FILE" ]]; then
        local last_check now
        last_check=$(cat "$UPDATE_CHECK_FILE" 2>/dev/null || echo 0)
        now=$(date +%s)
        (( now - last_check < 86400 )) && return 0
    fi

    date +%s > "$UPDATE_CHECK_FILE" 2>/dev/null || true

    local latest
    latest=$(curl -fsSL --connect-timeout 3 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/') || true

    [[ -z "${latest:-}" ]] && return 0

    if [[ "$latest" != "$VERSION" ]]; then
        echo ""
        warn "Update available: ${BOLD}v$VERSION${NC} → ${BOLD}v$latest${NC}"
        echo -e "  Run: ${BOLD}dploy update${NC} to upgrade"
        echo ""
    fi
}

# --- Self-update ---
self_update() {
    info "Checking for updates..."

    local latest
    latest=$(curl -fsSL --connect-timeout 5 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')

    [[ -z "$latest" ]] && err "Could not fetch latest version. Check your internet connection."

    if [[ "$latest" == "$VERSION" ]]; then
        log "Already on latest version (v$VERSION)"
        return 0
    fi

    info "Updating ${BOLD}v$VERSION${NC} → ${BOLD}v$latest${NC} ..."

    local tmp="/tmp/dploy_update_$$"
    curl -fsSL "$REPO_RAW/dploy.sh" -o "$tmp" || err "Download failed"

    if ! head -1 "$tmp" | grep -q "^#!/bin/bash"; then
        rm -f "$tmp"
        err "Downloaded file is not valid"
    fi

    chmod +x "$tmp"

    local current
    current=$(realpath "$0")

    if [[ -w "$current" ]]; then
        mv "$tmp" "$current"
    else
        info "Requires sudo to update $current"
        sudo mv "$tmp" "$current"
    fi

    date +%s > "$UPDATE_CHECK_FILE" 2>/dev/null || true
    log "Updated to ${BOLD}v$latest${NC}"
}

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
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        value="${value%\"}" && value="${value#\"}"
        value="${value%\'}" && value="${value#\'}"
        export "$key=$value"
    done < "$ENV_FILE"

    [[ -n "${SERVER:-}" ]] || err "SERVER is not set in .env"
    [[ -n "${DEPLOY_DIR:-}" ]] || err "DEPLOY_DIR is not set in .env"

    # Resolve SSH key
    if [[ -n "${SSH_KEY:-}" ]]; then
        SSH_KEY="${SSH_KEY/#\~/$HOME}"
        [[ -f "$SSH_KEY" ]] || err "SSH key not found: $SSH_KEY"
    else
        SSH_KEY=""
        for key in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
            if [[ -f "$key" ]]; then
                SSH_KEY="$key"
                break
            fi
        done
        [[ -n "$SSH_KEY" ]] || err "No SSH key found. Set SSH_KEY in .env or create one: ssh-keygen"
    fi

    SSH_PORT="${SSH_PORT:-22}"

    [[ "$DEPLOY_DIR" == /* ]] || err "DEPLOY_DIR must be an absolute path (starts with /)"

    # Build SSH/SCP options
    SSH_OPTS=(-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT")
    SCP_OPTS=(-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -P "$SSH_PORT")

    BUILD_CMD="${BUILD_CMD:-npm run build}"
    POST_DEPLOY_CMD="${POST_DEPLOY_CMD:-}"
}

# --- Security warnings (non-blocking) ---
check_security() {
    local ssh_user="${SERVER%%@*}"
    if [[ "$ssh_user" == "root" ]]; then
        warn "Deploying as ${BOLD}root${NC} — consider a dedicated deploy user"
        echo -e "  ${DIM}Create one: adduser deploy && mkdir -p $DEPLOY_DIR && chown deploy:deploy $DEPLOY_DIR${NC}"
    fi

    case "$DEPLOY_DIR" in
        /|/etc|/etc/*|/usr|/usr/*|/var|/root|/root/*|/bin|/bin/*|/sbin|/sbin/*)
            warn "DEPLOY_DIR=${BOLD}$DEPLOY_DIR${NC} is a sensitive system path"
            ;;
    esac
}

# --- Check SSH connectivity ---
check_ssh() {
    info "Checking SSH connection to ${BOLD}$SERVER:$SSH_PORT${NC} ..."
    if ! ssh "${SSH_OPTS[@]}" "$SERVER" "echo ok" &>/dev/null; then
        err "Cannot connect to $SERVER:$SSH_PORT
  Check: SSH_KEY=$SSH_KEY, server address, port, and firewall"
    fi
}

# --- Check write permission on server ---
check_permissions() {
    local perm_check
    perm_check=$(ssh "${SSH_OPTS[@]}" "$SERVER" bash -s "$DEPLOY_DIR" <<'PERMCHECK'
set -euo pipefail
D="$1"
while [[ ! -d "$D" && "$D" != "/" ]]; do
    D=$(dirname "$D")
done
if [[ -w "$D" ]]; then
    echo "OK"
else
    echo "FAIL:$D"
fi
PERMCHECK
    )

    if [[ "$perm_check" == FAIL:* ]]; then
        local blocked_dir="${perm_check#FAIL:}"
        local ssh_user="${SERVER%%@*}"
        err "No write permission to ${BOLD}$blocked_dir${NC}
  Fix: chown $ssh_user $DEPLOY_DIR
  Or use a user with access to this directory"
    fi
}

# --- Prompt with q/Esc/n to cancel, Enter/y to confirm ---
ask() {
    local prompt="$1"
    local default_yes="${2:-1}"  # 1 = default Y, 0 = default N

    if [[ "$default_yes" == "1" ]]; then
        echo -ne "  ${YELLOW}${prompt}${NC} ${BOLD}[Y/n/q]${NC} "
    else
        echo -ne "  ${YELLOW}${prompt}${NC} ${BOLD}[y/N/q]${NC} "
    fi

    while true; do
        IFS= read -rsn1 key
        case "$key" in
            $'\x1b')  # Esc
                read -rsn2 -t 0.1 _ 2>/dev/null || true  # Drain arrow sequence
                echo ""
                echo ""
                warn "Cancelled."
                exit 0
                ;;
            q|Q)
                echo ""
                echo ""
                warn "Cancelled."
                exit 0
                ;;
            n|N)
                echo "n"
                echo ""
                warn "Cancelled."
                exit 0
                ;;
            y|Y)
                echo "y"
                echo ""
                return 0
                ;;
            "")  # Enter
                if [[ "$default_yes" == "1" ]]; then
                    echo "y"
                    echo ""
                    return 0
                else
                    echo "n"
                    echo ""
                    warn "Cancelled."
                    exit 0
                fi
                ;;
        esac
    done
}

# --- Confirm prompt ---
confirm() {
    local dist_dir="$1"
    local file_count dir_size

    file_count=$(find "$dist_dir" -type f | wc -l | tr -d ' ')
    dir_size=$(du -sh "$dist_dir" | cut -f1 | tr -d ' ')

    echo -e "  ${DIM}───────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Project${NC}   $(basename "$(pwd)")"
    echo -e "  ${BOLD}Source${NC}    ${CYAN}$dist_dir/${NC} ${DIM}($file_count files, $dir_size)${NC}"
    echo -e "  ${BOLD}Server${NC}    ${CYAN}$SERVER${NC}${DIM}:$SSH_PORT${NC}"
    echo -e "  ${BOLD}Key${NC}       ${DIM}$(basename "$SSH_KEY")${NC}"
    echo -e "  ${BOLD}Deploy to${NC} ${CYAN}$DEPLOY_DIR${NC}"
    [[ -n "$POST_DEPLOY_CMD" ]] && \
    echo -e "  ${BOLD}Hook${NC}      ${DIM}$POST_DEPLOY_CMD${NC}"
    [[ -f "$IGNORE_FILE" ]] && \
    echo -e "  ${BOLD}Exclude${NC}   ${DIM}.dployignore ($(grep -cv '^\s*#\|^\s*$' "$IGNORE_FILE" 2>/dev/null || echo 0) rules)${NC}"
    echo -e "  ${DIM}───────────────────────────────────────────${NC}"
    echo ""

    if [[ "${SKIP_CONFIRM:-}" == "1" ]]; then
        log "Auto-confirmed (-y flag)"
        return 0
    fi

    ask "Deploy?" 1
}


# --- Build tar exclude args from .dployignore ---
build_exclude_args() {
    local excludes=()
    if [[ -f "$IGNORE_FILE" ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue
            excludes+=(--exclude="$line")
        done < "$IGNORE_FILE"
    fi
    echo "${excludes[@]}"
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

    # --- Uninstall ---
    uninstall)
        if [[ ! -f "$INSTALL_PATH" ]]; then
            warn "dploy is not installed at $INSTALL_PATH"
            exit 0
        fi

        echo ""
        warn "This will remove dploy from $INSTALL_PATH"
        ask "Uninstall?" 0

        sudo rm -f "$INSTALL_PATH"
        rm -f "$UPDATE_CHECK_FILE"
        log "dploy has been removed."
        ;;

    # --- Init config templates ---
    init)
        if [[ -f "$ENV_FILE" ]]; then
            warn ".env already exists:"
            echo -e "${DIM}$(cat "$ENV_FILE")${NC}"
        else
            cat > "$ENV_FILE" <<'TEMPLATE'
# dploy configuration
#
# TIP: For better security, use a deploy user instead of root:
#   adduser deploy && mkdir -p /var/www/myapp && chown deploy:deploy /var/www/myapp
#
SERVER=root@your-server-ip
DEPLOY_DIR=/var/www/myapp/frontend
# SSH_KEY=~/.ssh/id_rsa            (optional, auto-detects default key)
# SSH_PORT=22                      (optional, default: 22)
# BUILD_CMD=npm run build
# POST_DEPLOY_CMD=systemctl reload nginx
TEMPLATE
            log "Created .env — edit it with your server details."
        fi

        # .env.example (safe to commit)
        if [[ ! -f ".env.example" ]]; then
            cat > ".env.example" <<'EXAMPLE'
# dploy configuration — copy to .env and fill in your values
# cp .env.example .env
SERVER=root@your-server-ip
DEPLOY_DIR=/var/www/myapp/frontend
# SSH_KEY=~/.ssh/id_rsa
# SSH_PORT=22
# BUILD_CMD=npm run build
# POST_DEPLOY_CMD=systemctl reload nginx
EXAMPLE
            log "Created .env.example — safe to commit for teammates."
        fi

        # .dployignore
        if [[ ! -f "$IGNORE_FILE" ]]; then
            cat > "$IGNORE_FILE" <<'IGNOREFILE'
# dploy ignore — files excluded from deployment
# Uses tar --exclude patterns (glob syntax)

# Source maps
*.map

# Dev/test files
*.test.*
*.spec.*
__tests__
IGNOREFILE
            log "Created .dployignore — edit to exclude files from deploy."
        fi
        ;;

    # --- Build + Deploy ---
    build)
        load_env

        info "Building with: ${BOLD}$BUILD_CMD${NC}"
        if ! bash -c "$BUILD_CMD"; then
            err "Build failed!"
        fi
        log "Build complete."

        [[ "$SKIP_CONFIRM" == "1" ]] && exec "$0" -y deploy || exec "$0" deploy
        ;;

    # --- Update ---
    update)
        self_update
        ;;

    # --- Doctor (run all checks) ---
    doctor)
        echo ""
        echo -e "  ${BOLD}${CYAN}dploy doctor${NC} ${DIM}v$VERSION${NC}"
        echo -e "  ${DIM}─────────────────────────────────${NC}"
        echo ""
        PASS=0
        FAIL=0
        WARN=0

        # 1. Check .env
        if [[ -f "$ENV_FILE" ]]; then
            log ".env file found"
            PASS=$((PASS + 1))
        else
            err_msg="${RED}✗${NC} .env file not found — run ${BOLD}dploy init${NC}"
            echo -e "$err_msg"
            FAIL=$((FAIL + 1))
            echo ""
            echo -e "  ${BOLD}Results:${NC} $PASS passed, $FAIL failed, $WARN warnings"
            exit 1
        fi

        load_env

        # 2. Check SSH key
        if [[ -f "$SSH_KEY" ]]; then
            log "SSH key found: $(basename "$SSH_KEY")"
            PASS=$((PASS + 1))

            # Check key permissions
            KEY_PERMS=$(stat -f '%Lp' "$SSH_KEY" 2>/dev/null || stat -c '%a' "$SSH_KEY" 2>/dev/null)
            if [[ "$KEY_PERMS" == "600" || "$KEY_PERMS" == "400" ]]; then
                log "SSH key permissions OK ($KEY_PERMS)"
                PASS=$((PASS + 1))
            else
                warn "SSH key permissions are $KEY_PERMS (should be 600)"
                echo -e "  ${DIM}Fix: chmod 600 $SSH_KEY${NC}"
                WARN=$((WARN + 1))
            fi
        else
            echo -e "${RED}✗${NC} SSH key not found"
            FAIL=$((FAIL + 1))
        fi

        # 3. Check SSH connection
        if ssh "${SSH_OPTS[@]}" "$SERVER" "echo ok" &>/dev/null; then
            log "SSH connection to $SERVER:$SSH_PORT"
            PASS=$((PASS + 1))
        else
            echo -e "${RED}✗${NC} Cannot connect to $SERVER:$SSH_PORT"
            FAIL=$((FAIL + 1))
            echo ""
            echo -e "  ${BOLD}Results:${NC} $PASS passed, $FAIL failed, $WARN warnings"
            exit 1
        fi

        # 4. Check root warning
        SSH_USER="${SERVER%%@*}"
        if [[ "$SSH_USER" == "root" ]]; then
            warn "Deploying as root — consider a deploy user"
            WARN=$((WARN + 1))
        else
            log "Non-root user: $SSH_USER"
            PASS=$((PASS + 1))
        fi

        # 5. Check write permissions
        PERM_CHECK=$(ssh "${SSH_OPTS[@]}" "$SERVER" bash -s "$DEPLOY_DIR" <<'PERMCHECK'
set -euo pipefail
D="$1"
while [[ ! -d "$D" && "$D" != "/" ]]; do
    D=$(dirname "$D")
done
if [[ -w "$D" ]]; then echo "OK"; else echo "FAIL:$D"; fi
PERMCHECK
        )
        if [[ "$PERM_CHECK" == "OK" ]]; then
            log "Write permission to $DEPLOY_DIR"
            PASS=$((PASS + 1))
        else
            echo -e "${RED}✗${NC} No write permission to ${PERM_CHECK#FAIL:}"
            echo -e "  ${DIM}Fix: chown $SSH_USER $DEPLOY_DIR${NC}"
            FAIL=$((FAIL + 1))
        fi

        # 6. Check dangerous paths
        case "$DEPLOY_DIR" in
            /|/etc|/etc/*|/usr|/usr/*|/var|/root|/root/*|/bin|/bin/*|/sbin|/sbin/*)
                warn "DEPLOY_DIR is a sensitive system path: $DEPLOY_DIR"
                WARN=$((WARN + 1))
                ;;
            *)
                log "DEPLOY_DIR path is safe: $DEPLOY_DIR"
                PASS=$((PASS + 1))
                ;;
        esac

        # 7. Check disk space
        DISK_INFO=$(ssh "${SSH_OPTS[@]}" "$SERVER" bash -s "$DEPLOY_DIR" <<'DISK'
set -euo pipefail
D="$1"
while [[ ! -d "$D" && "$D" != "/" ]]; do D=$(dirname "$D"); done
USAGE=$(df "$D" | tail -1 | awk '{print $5}' | tr -d '%')
FREE=$(df -h "$D" | tail -1 | awk '{print $4}')
echo "$USAGE:$FREE"
DISK
        )
        DISK_USAGE="${DISK_INFO%%:*}"
        DISK_FREE="${DISK_INFO#*:}"
        if (( DISK_USAGE > 90 )); then
            echo -e "${RED}✗${NC} Disk almost full: ${DISK_USAGE}% used ($DISK_FREE free)"
            FAIL=$((FAIL + 1))
        elif (( DISK_USAGE > 80 )); then
            warn "Disk usage high: ${DISK_USAGE}% used ($DISK_FREE free)"
            WARN=$((WARN + 1))
        else
            log "Disk space OK: ${DISK_USAGE}% used ($DISK_FREE free)"
            PASS=$((PASS + 1))
        fi

        # 8. Check .dployignore
        if [[ -f "$IGNORE_FILE" ]]; then
            RULE_COUNT=$(grep -cv '^\s*#\|^\s*$' "$IGNORE_FILE" 2>/dev/null || echo 0)
            log ".dployignore found ($RULE_COUNT rules)"
            PASS=$((PASS + 1))
        else
            warn "No .dployignore — all files will be deployed (including *.map)"
            WARN=$((WARN + 1))
        fi

        # 9. Check POST_DEPLOY_CMD
        if [[ -n "$POST_DEPLOY_CMD" ]]; then
            if ssh "${SSH_OPTS[@]}" "$SERVER" "command -v ${POST_DEPLOY_CMD%% *}" &>/dev/null; then
                log "Post-deploy command found: $POST_DEPLOY_CMD"
                PASS=$((PASS + 1))
            else
                warn "Post-deploy command not found on server: ${POST_DEPLOY_CMD%% *}"
                WARN=$((WARN + 1))
            fi
        fi

        # 10. Check build folder
        if DIST=$(detect_dist); then
            DIST_FILES=$(find "$DIST" -type f | wc -l | tr -d ' ')
            log "Build folder detected: $DIST/ ($DIST_FILES files)"
            PASS=$((PASS + 1))
        else
            warn "No build folder found — run your build command first"
            WARN=$((WARN + 1))
        fi

        # Summary
        echo ""
        if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
            log "${BOLD}All checks passed!${NC} ($PASS/$PASS)"
        elif [[ $FAIL -eq 0 ]]; then
            log "${BOLD}$PASS passed${NC}, ${YELLOW}$WARN warnings${NC}"
        else
            echo -e "${RED}✗${NC} ${BOLD}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$WARN warnings${NC}"
            exit 1
        fi
        ;;

    # --- Deploy ---
    deploy)
        check_update
        load_env
        check_security
        header
        timer_start

        TOTAL_STEPS=4
        [[ -n "$POST_DEPLOY_CMD" ]] && TOTAL_STEPS=5

        DIST_DIR=$(detect_dist) || err "No build folder found!
    Checked: dist/, build/, out/, .next/
    Run your build command first: ${BOLD}$BUILD_CMD${NC}"

        confirm "$DIST_DIR"

        step 1 "$TOTAL_STEPS" "Connecting"
        check_ssh
        check_permissions

        ARCHIVE_NAME="dploy_$(date +%s).tar.gz"

        EXCLUDE_ARGS=""
        if [[ -f "$IGNORE_FILE" ]]; then
            EXCLUDE_ARGS=$(build_exclude_args)
        fi

        step 2 "$TOTAL_STEPS" "Packaging"
        step_start=$(date +%s)
        # shellcheck disable=SC2086
        tar -czf "$ARCHIVE_NAME" $EXCLUDE_ARGS -C "$DIST_DIR" .
        SIZE=$(du -h "$ARCHIVE_NAME" | cut -f1 | tr -d ' ')
        log "Archived ${BOLD}$DIST_DIR/${NC} → ${SIZE} ${DIM}$(( $(date +%s) - step_start ))s${NC}"

        step 3 "$TOTAL_STEPS" "Uploading ${DIM}($SIZE)${NC}"
        step_start=$(date +%s)
        if [[ -t 1 ]]; then
            # Show SCP's native progress bar (%, size, speed, ETA)
            scp "${SCP_OPTS[@]}" "$ARCHIVE_NAME" "$SERVER:/tmp/$ARCHIVE_NAME"
        else
            scp -q "${SCP_OPTS[@]}" "$ARCHIVE_NAME" "$SERVER:/tmp/$ARCHIVE_NAME"
        fi
        log "Sent to ${BOLD}$SERVER${NC} ${DIM}$(( $(date +%s) - step_start ))s${NC}"

        step 4 "$TOTAL_STEPS" "Deploying"
        step_start=$(date +%s)
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

        if [[ "$RESULT" != OK:* ]]; then
            err "Deploy failed on server!
  $RESULT"
        fi

        log "Extracted ${BOLD}${RESULT#OK:}${NC} files ${DIM}$(( $(date +%s) - step_start ))s${NC}"

        # Run post-deploy hook
        if [[ -n "$POST_DEPLOY_CMD" ]]; then
            step 5 "$TOTAL_STEPS" "Post-deploy"
            step_start=$(date +%s)
            HOOK_OUTPUT=$(ssh "${SSH_OPTS[@]}" "$SERVER" "$POST_DEPLOY_CMD" 2>&1) && HOOK_OK=1 || HOOK_OK=0

            if [[ "$HOOK_OK" == "1" ]]; then
                log "${DIM}$POST_DEPLOY_CMD${NC} ${DIM}$(( $(date +%s) - step_start ))s${NC}"
            else
                warn "Post-deploy command failed (deploy itself succeeded)"
                if echo "$HOOK_OUTPUT" | grep -qi "permission denied\|not permitted\|sudo"; then
                    SSH_USER="${SERVER%%@*}"
                    echo -e "    ${DIM}Hint: add passwordless sudo for this command:${NC}"
                    echo -e "    ${DIM}echo '$SSH_USER ALL=(ALL) NOPASSWD: $POST_DEPLOY_CMD' | sudo tee /etc/sudoers.d/dploy${NC}"
                else
                    echo -e "    ${DIM}$HOOK_OUTPUT${NC}"
                fi
            fi
        fi

        ARCHIVE_NAME=""
        echo ""
        echo -e "  ${DIM}───────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}${BOLD}Done!${NC} Deployed to ${CYAN}$DEPLOY_DIR${NC} in ${BOLD}$(timer_elapsed)${NC}"
        echo ""
        ;;

    # --- Rollback ---
    rollback)
        load_env
        header
        check_ssh

        # Fetch available backups
        BACKUP_LIST=$(ssh "${SSH_OPTS[@]}" "$SERVER" bash -s "$DEPLOY_DIR" <<'LIST_BACKUPS'
set -euo pipefail
D="$1"
BACKUPS=$(ls -dt "${D}_backup_"* 2>/dev/null) || true
if [[ -z "${BACKUPS:-}" ]]; then
    echo "NONE"
    exit 0
fi
INDEX=1
while IFS= read -r backup; do
    NAME=$(basename "$backup")
    TS=$(echo "$NAME" | grep -o '[0-9]\{8\}_[0-9]\{6\}$') || true
    if [[ -n "${TS:-}" ]]; then
        DATE="${TS:0:4}-${TS:4:2}-${TS:6:2} ${TS:9:2}:${TS:11:2}:${TS:13:2}"
    else
        DATE="unknown"
    fi
    FILES=$(find "$backup" -type f | wc -l | tr -d ' ')
    SIZE=$(du -sh "$backup" | cut -f1 | tr -d ' ')
    echo "$INDEX|$NAME|$DATE|$FILES|$SIZE"
    INDEX=$((INDEX + 1))
done <<< "$BACKUPS"
LIST_BACKUPS
        )

        [[ "$BACKUP_LIST" == "NONE" ]] && err "No backups found on server"

        BACKUP_COUNT=$(echo "$BACKUP_LIST" | wc -l | tr -d ' ')

        # Store backup lines in arrays
        BACKUP_DATES=()
        BACKUP_NAMES=()
        BACKUP_LABELS=()
        while IFS='|' read -r idx name date files size; do
            BACKUP_NAMES+=("$name")
            BACKUP_DATES+=("$date")
            if [[ "$idx" == "1" ]]; then
                BACKUP_LABELS+=("$date  ${DIM}$files files  $size${NC}  ${GREEN}latest${NC}")
            else
                BACKUP_LABELS+=("$date  ${DIM}$files files  $size${NC}")
            fi
        done <<< "$BACKUP_LIST"

        if [[ "${SKIP_CONFIRM:-}" == "1" ]]; then
            PICK=0
            log "Auto-selected latest backup (-y flag)"
        elif [[ -t 0 ]]; then
            # Interactive arrow-key selector
            PICK=0
            echo -e "  ${BOLD}Select backup${NC} ${DIM}(↑/↓ move, Enter confirm, q cancel)${NC}"
            echo -e "  ${DIM}───────────────────────────────────────────${NC}"

            # Function to draw the list
            draw_list() {
                for i in $(seq 0 $((BACKUP_COUNT - 1))); do
                    printf '\033[2K'  # Clear line
                    if [[ $i -eq $PICK ]]; then
                        echo -e "  ${CYAN}▸${NC} ${BOLD}${BACKUP_LABELS[$i]}  ${DIM}↵ enter to rollback${NC}"
                    else
                        echo -e "    ${BACKUP_LABELS[$i]}"
                    fi
                done
            }

            # Draw initial list
            draw_list

            # Hide cursor
            printf '\033[?25l'
            trap 'printf "\033[?25h"; cleanup' EXIT INT TERM

            while true; do
                IFS= read -rsn1 key
                if [[ "$key" == $'\x1b' ]]; then
                    read -rsn2 arrow
                    case "$arrow" in
                        '[A') (( PICK > 0 )) && PICK=$((PICK - 1)) ;;
                        '[B') (( PICK < BACKUP_COUNT - 1 )) && PICK=$((PICK + 1)) ;;
                        *)    # Bare Esc (no arrow sequence)
                              printf '\033[?25h'
                              echo ""
                              warn "Cancelled."
                              exit 0 ;;
                    esac
                elif [[ "$key" == "q" || "$key" == "Q" ]]; then
                    printf '\033[?25h'
                    echo ""
                    warn "Cancelled."
                    exit 0
                elif [[ "$key" == "" ]]; then
                    break
                fi

                # Redraw
                printf "\033[${BACKUP_COUNT}A"
                draw_list
            done

            # Show cursor again
            printf '\033[?25h'
            echo ""
        else
            # Non-interactive fallback
            read -rp "$(echo -e "  ${YELLOW}Select backup${NC} ${BOLD}[1-$BACKUP_COUNT]${NC} ${DIM}(default: 1):${NC} ")" input
            PICK=$(( ${input:-1} - 1 ))
        fi

        # Validate
        if (( PICK < 0 || PICK >= BACKUP_COUNT )); then
            err "Invalid selection"
        fi

        # Get selected backup
        SELECTED_NAME="${BACKUP_NAMES[$PICK]}"
        SELECTED_DATE="${BACKUP_DATES[$PICK]}"

        echo ""
        warn "This will replace current deployment with backup from ${BOLD}$SELECTED_DATE${NC}"
        echo ""

        if [[ "${SKIP_CONFIRM:-}" != "1" ]]; then
            ask "Rollback?" 1
        fi

        info "Rolling back to ${BOLD}$SELECTED_DATE${NC} ..."

        RESULT=$(ssh "${SSH_OPTS[@]}" "$SERVER" bash -s "$DEPLOY_DIR" "$SELECTED_NAME" <<'ROLLBACK'
set -euo pipefail
DEPLOY_DIR="$1"
BACKUP_NAME="$2"
BACKUP_DIR="$(dirname "$DEPLOY_DIR")/$BACKUP_NAME"

if [[ ! -d "$BACKUP_DIR" ]]; then
    echo "FAIL:Backup not found: $BACKUP_NAME"
    exit 1
fi

rm -rf "${DEPLOY_DIR:?}"/*
cp -r "$BACKUP_DIR"/* "$DEPLOY_DIR"/
rm -rf "$BACKUP_DIR"

REMAINING=$(ls -d "${DEPLOY_DIR}_backup_"* 2>/dev/null | wc -l | tr -d ' ')
echo "OK:$REMAINING"
ROLLBACK
        )

        if [[ "$RESULT" == OK:* ]]; then
            REMAINING="${RESULT#OK:}"
            log "Rolled back to: ${BOLD}$SELECTED_DATE${NC}"
            [[ "$REMAINING" -gt 0 ]] && info "$REMAINING backup(s) remaining" || warn "No more backups available"
        else
            err "Rollback failed: ${RESULT#FAIL:}"
        fi
        ;;

    # --- Logs (deploy history) ---
    logs)
        load_env
        check_ssh

        info "Deploy history for ${BOLD}$SERVER:$DEPLOY_DIR${NC}"
        echo ""

        ssh "${SSH_OPTS[@]}" "$SERVER" bash -s "$DEPLOY_DIR" <<'LOGS'
set -euo pipefail
D="$1"

# Current deployment
if [[ -d "$D" ]] && find "$D" -maxdepth 1 -type f | read -r; then
    FILES=$(find "$D" -type f | wc -l | tr -d ' ')
    SIZE=$(du -sh "$D" | cut -f1 | tr -d ' ')
    MOD=$(stat -c '%Y' "$D" 2>/dev/null || stat -f '%m' "$D" 2>/dev/null)
    MOD_DATE=$(date -d "@$MOD" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$MOD" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
    echo "  ● CURRENT    $MOD_DATE    $FILES files    $SIZE"
else
    echo "  ○ NOT DEPLOYED"
fi

# Backup history
BACKUPS=$(ls -dt "${D}_backup_"* 2>/dev/null) || true
if [[ -n "${BACKUPS:-}" ]]; then
    INDEX=1
    while IFS= read -r backup; do
        NAME=$(basename "$backup")
        TS=$(echo "$NAME" | grep -o '[0-9]\{8\}_[0-9]\{6\}$') || true
        if [[ -n "${TS:-}" ]]; then
            DATE="${TS:0:4}-${TS:4:2}-${TS:6:2} ${TS:9:2}:${TS:11:2}:${TS:13:2}"
        else
            DATE="unknown"
        fi
        FILES=$(find "$backup" -type f | wc -l | tr -d ' ')
        SIZE=$(du -sh "$backup" | cut -f1 | tr -d ' ')
        echo "  ○ BACKUP #$INDEX  $DATE    $FILES files    $SIZE"
        INDEX=$((INDEX + 1))
    done <<< "$BACKUPS"
else
    echo "  (no backups)"
fi
LOGS
        ;;

    # --- SSH into server ---
    ssh)
        load_env
        info "Connecting to ${BOLD}$SERVER:$SSH_PORT${NC} ..."
        exec ssh "${SSH_OPTS[@]}" "$SERVER"
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
    echo "  Status:   NOT DEPLOYED"
    exit 0
fi

FILE_COUNT=$(find "$D" -type f | wc -l | tr -d ' ')
DIR_SIZE=$(du -sh "$D" | cut -f1 | tr -d ' ')
MODIFIED=$(stat -c '%Y' "$D" 2>/dev/null || stat -f '%m' "$D" 2>/dev/null)
MODIFIED_DATE=$(date -d "@$MODIFIED" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$MODIFIED" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")

BACKUPS=$(ls -d "${D}_backup_"* 2>/dev/null | wc -l | tr -d ' ')
DISK_FREE=$(df -h "$D" | tail -1 | awk '{print $4}')

echo "  Status:   DEPLOYED"
echo "  Files:    $FILE_COUNT"
echo "  Size:     $DIR_SIZE"
echo "  Modified: $MODIFIED_DATE"
echo "  Backups:  $BACKUPS"
echo "  Disk:     $DISK_FREE free"
STATUS
        ;;

    # --- Version ---
    -v|--version|version)
        echo "dploy v$VERSION"
        ;;

    # --- Help ---
    -h|--help|help)
        echo ""
        echo -e "  ${BOLD}${CYAN}dploy${NC} ${DIM}v$VERSION${NC}  ${DIM}— deploy frontend builds via SSH${NC}"
        echo ""
        echo -e "  ${BOLD}Usage${NC}"
        echo -e "    ${CYAN}dploy${NC}                 detect build folder and deploy"
        echo -e "    ${CYAN}dploy build${NC}            build first, then deploy"
        echo -e "    ${CYAN}dploy rollback${NC}         pick and restore a backup"
        echo -e "    ${CYAN}dploy logs${NC}             deploy history and backups"
        echo -e "    ${CYAN}dploy ssh${NC}              open SSH session to server"
        echo -e "    ${CYAN}dploy status${NC}           current deployment info"
        echo -e "    ${CYAN}dploy doctor${NC}           check setup (SSH, perms, disk)"
        echo -e "    ${CYAN}dploy update${NC}           update dploy to latest"
        echo -e "    ${CYAN}dploy init${NC}             create config templates"
        echo -e "    ${CYAN}dploy install${NC}          install to /usr/local/bin"
        echo -e "    ${CYAN}dploy uninstall${NC}        remove from system"
        echo ""
        echo -e "  ${BOLD}Flags${NC}"
        echo -e "    ${CYAN}-y, --yes${NC}              skip confirmation prompts"
        echo ""
        echo -e "  ${BOLD}Config ${DIM}(.env)${NC}"
        echo -e "    ${CYAN}SERVER${NC}                 ${DIM}root@192.168.1.10${NC}"
        echo -e "    ${CYAN}DEPLOY_DIR${NC}             ${DIM}/var/www/app (absolute path)${NC}"
        echo -e "    ${CYAN}SSH_KEY${NC}                ${DIM}~/.ssh/id_rsa (auto-detect)${NC}"
        echo -e "    ${CYAN}SSH_PORT${NC}               ${DIM}22 (default)${NC}"
        echo -e "    ${CYAN}BUILD_CMD${NC}              ${DIM}npm run build (default)${NC}"
        echo -e "    ${CYAN}POST_DEPLOY_CMD${NC}        ${DIM}command to run after deploy${NC}"
        echo ""
        echo -e "  ${BOLD}Files${NC}"
        echo -e "    ${DIM}.env                  server config${NC}"
        echo -e "    ${DIM}.env.example           template for teammates${NC}"
        echo -e "    ${DIM}.dployignore           exclude patterns (*.map, etc)${NC}"
        echo ""
        echo -e "  ${BOLD}Detects${NC}  ${DIM}dist/  build/  out/  .next/${NC}"
        echo ""
        ;;

    # --- Unknown command ---
    *)
        err "Unknown command: $CMD
  Run ${BOLD}dploy help${NC} for usage"
        ;;
esac
