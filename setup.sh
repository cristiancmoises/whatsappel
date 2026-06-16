#!/usr/bin/env bash
# whatsappel setup — build pqenv, install it, create config, generate a token.
# Idempotent: safe to re-run; never overwrites an existing .env or PQ keys.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${WHATSAPPEL_BIN:-$HOME/.local/bin}"
CONFIG="${WHATSAPPEL_CONFIG:-$HOME/.config/whatsappel}"
ENV_FILE="$REPO/.env"

say()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

say "Checking dependencies"
need=()
command -v guile  >/dev/null 2>&1 || need+=("guile (guile-3.0)")
guile -c '(use-modules (json))' >/dev/null 2>&1 || need+=("guile-json")
command -v emacs  >/dev/null 2>&1 || need+=("emacs")
command -v cargo  >/dev/null 2>&1 || need+=("cargo (rustup)")
if [ "${#need[@]}" -gt 0 ]; then
  warn "Missing: ${need[*]}"
  cat <<'EOT'
  Install, e.g.:
    Debian/Ubuntu: sudo apt install guile-3.0 guile-json emacs-nox
    Arch:          sudo pacman -S guile guile-json emacs
    Fedora:        sudo dnf install guile guile-json emacs
    Rust:          curl https://sh.rustup.rs -sSf | sh
EOT
  die "Install the above and re-run ./setup.sh"
fi
say "All dependencies present"

say "Building pqenv (release)"
( cd "$REPO/pqenv" && cargo build --release --quiet )
mkdir -p "$BIN"
install -m 0755 "$REPO/pqenv/target/release/pqenv" "$BIN/pqenv"
say "Installed pqenv -> $BIN/pqenv"
case ":$PATH:" in *":$BIN:"*) : ;; *) warn "Add $BIN to your PATH (e.g. in ~/.profile)";; esac

say "Creating config directories"
mkdir -p "$CONFIG/pq/contacts"
chmod 700 "$CONFIG" "$CONFIG/pq" 2>/dev/null || true

if [ -f "$ENV_FILE" ]; then
  say ".env already exists — leaving it untouched"
else
  say "Generating .env with a fresh bridge token"
  token="$(openssl rand -hex 32 2>/dev/null || head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  sed -e "s|^export WHATSAPPEL_TOKEN=.*|export WHATSAPPEL_TOKEN=\"$token\"|" \
      "$REPO/env.example" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  warn "Edit $ENV_FILE and set WUZAPI_TOKEN to your wuzapi user token."
fi

say "Generating PQ identity (if absent)"
if [ -f "$CONFIG/pq/identity.secret" ]; then
  say "PQ identity already exists — keeping it"
else
  "$BIN/pqenv" keygen --out "$CONFIG/pq/identity"
fi

cat <<EOT

$(say "Setup complete")
Next:
  1) Start wuzapi (see README) and put its user token in $ENV_FILE (WUZAPI_TOKEN).
  2) Run the bridge:      make run     (or: set -a; . ./.env; set +a; guile whatsappel.scm)
  3) In Emacs:            (require 'whatsapp)
                          (setq whatsapp-bridge-token "<WHATSAPPEL_TOKEN from .env>")
                          (global-set-key (kbd "C-c w") whatsapp-prefix-map)
     then  M-x whatsapp-connect  ->  M-x whatsapp-qr  ->  M-x whatsapp
  4) PQ: share $CONFIG/pq/identity.public with a contact, import theirs with
         C-c w i, then compose encrypted with C-c C-e in a chat.
EOT
