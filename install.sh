#!/bin/bash
# === dploy Installer ===
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ganiyevuz/dploy/main/install.sh | bash
#
set -euo pipefail

REPO="ganiyevuz/dploy"
INSTALL_DIR="/usr/local/bin"
BIN_NAME="dploy"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}✓${NC} $1"; }
err()  { echo -e "${RED}✗${NC} $1"; exit 1; }
info() { echo -e "${CYAN}→${NC} $1"; }

# Detect OS
OS="$(uname -s)"
case "$OS" in
    Linux*)  PLATFORM="linux" ;;
    Darwin*) PLATFORM="macos" ;;
    *)       err "Unsupported OS: $OS. Use WSL on Windows." ;;
esac

info "Installing ${BOLD}dploy${NC} for $PLATFORM..."

# Download latest
DOWNLOAD_URL="https://raw.githubusercontent.com/$REPO/main/dploy.sh"

if command -v curl &>/dev/null; then
    curl -fsSL "$DOWNLOAD_URL" -o "/tmp/$BIN_NAME"
elif command -v wget &>/dev/null; then
    wget -qO "/tmp/$BIN_NAME" "$DOWNLOAD_URL"
else
    err "curl or wget is required"
fi

# Install
if [[ -w "$INSTALL_DIR" ]]; then
    mv "/tmp/$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"
    chmod +x "$INSTALL_DIR/$BIN_NAME"
else
    info "Requires sudo to install to $INSTALL_DIR"
    sudo mv "/tmp/$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"
    sudo chmod +x "$INSTALL_DIR/$BIN_NAME"
fi

log "Installed to ${BOLD}$INSTALL_DIR/$BIN_NAME${NC}"
echo ""
echo -e "  Get started:"
echo -e "    ${BOLD}cd your-frontend-project${NC}"
echo -e "    ${BOLD}dploy init${NC}      # create .env config"
echo -e "    ${BOLD}dploy${NC}           # deploy to server"
echo ""