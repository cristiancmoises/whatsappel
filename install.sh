#!/usr/bin/env bash
set -eo pipefail

# WhatsApp.el — Installer
# Usage: ./install.sh [--systemd] [--docker]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/share/whatsappel"
EMACS_DIR="${HOME}/.emacs.d/lisp"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}→${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }

# --- Check required files exist ---

for f in server.js package.json whatsapp.el; do
    if [ ! -f "${SCRIPT_DIR}/${f}" ]; then
        err "Missing ${f} — run this script from the whatsappel directory"
        exit 1
    fi
done

# --- Check dependencies ---

echo ""
echo -e "${BOLD}WhatsApp.el Installer${NC}"
echo ""

info "Checking dependencies..."

for cmd in node npm curl; do
    if command -v "$cmd" &>/dev/null; then
        ok "${cmd} found: $(command -v "$cmd")"
    else
        err "${cmd} not found. Install it first."
        if [ "$cmd" = "node" ] || [ "$cmd" = "npm" ]; then
            err "  Install Node.js >= 18: https://nodejs.org/"
            err "  Or: curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt install -y nodejs"
        elif [ "$cmd" = "curl" ]; then
            err "  Install: sudo apt install curl"
        fi
        exit 1
    fi
done

# Check Node.js version
NODE_VER="$(node -v 2>/dev/null | tr -d 'v' | cut -d. -f1)"
if [ -z "$NODE_VER" ] || [ "$NODE_VER" -lt 18 ] 2>/dev/null; then
    err "Node.js >= 18 required (found: $(node -v 2>/dev/null || echo 'unknown'))"
    err "  Update: https://nodejs.org/ or use nvm"
    exit 1
fi
ok "Node.js v${NODE_VER} (>= 18 required)"

# Check optional dependencies
for opt in sox ffmpeg mpv emacs; do
    if command -v "$opt" &>/dev/null; then
        ok "${opt} found (optional)"
    else
        info "${opt} not found (optional — voice/audio/emacs features)"
    fi
done

echo ""

# --- Install server ---

info "Installing server to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
cp "${SCRIPT_DIR}/server.js" "${INSTALL_DIR}/"
cp "${SCRIPT_DIR}/package.json" "${INSTALL_DIR}/"

cd "${INSTALL_DIR}"
info "Running npm install (this may take a minute)..."
npm install --omit=dev 2>&1 | tail -3
ok "Server installed to ${INSTALL_DIR}"

# --- Install Emacs package ---

info "Installing whatsapp.el to ${EMACS_DIR}..."
mkdir -p "${EMACS_DIR}"
cp "${SCRIPT_DIR}/whatsapp.el" "${EMACS_DIR}/"
ok "whatsapp.el installed to ${EMACS_DIR}"

# --- Optional: systemd ---

if [ "${1:-}" = "--systemd" ]; then
    echo ""
    if [ ! -f "${SCRIPT_DIR}/whatsappel.service" ]; then
        err "whatsappel.service not found"
    else
        info "Installing systemd user service..."
        mkdir -p "${HOME}/.config/systemd/user"
        cp "${SCRIPT_DIR}/whatsappel.service" "${HOME}/.config/systemd/user/"
        systemctl --user daemon-reload 2>/dev/null || true
        ok "Service installed"
        echo ""
        info "Enable:  systemctl --user enable --now whatsappel"
        info "Status:  systemctl --user status whatsappel"
        info "Logs:    journalctl --user -u whatsappel -f"
    fi
fi

# --- Optional: Docker ---

if [ "${1:-}" = "--docker" ]; then
    echo ""
    if ! command -v docker &>/dev/null; then
        err "docker not found. Install Docker first."
    else
        info "Building Docker image..."
        cd "${SCRIPT_DIR}"
        docker build -t whatsappel .
        ok "Docker image built"
        echo ""
        info "Run:   docker compose up -d"
        info "Logs:  docker compose logs -f"
        info "Stop:  docker compose down"
    fi
fi

# --- Done ---

echo ""
echo -e "${GREEN}${BOLD}Installation complete!${NC}"
echo ""
echo "1. Start the server:"
echo ""
echo -e "   ${CYAN}cd ${INSTALL_DIR} && node server.js${NC}"
echo ""
echo "   Scan the QR code with WhatsApp > Linked Devices > Link a Device"
echo ""
echo "2. Add to your Emacs config (~/.emacs.d/init.el):"
echo ""
echo -e "   ${CYAN}(add-to-list 'load-path \"${EMACS_DIR}\")${NC}"
echo -e "   ${CYAN}(require 'whatsapp)${NC}"
echo ""
echo "3. In Emacs:"
echo ""
echo -e "   ${CYAN}M-x whatsapp-connect${NC}"
echo ""
