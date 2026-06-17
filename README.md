<div align="center">

<img src="assets/logo.png" alt="whatsappel" width="200">

# whatsapp.el — telega-style Emacs WhatsApp client

**Guile bridge · wuzapi engine · no Baileys · no JavaScript**

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0--only-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-3.0.0-green.svg)](CHANGELOG.md)
[![Emacs](https://img.shields.io/badge/Emacs-%E2%89%A528-7F5AB6.svg)](https://www.gnu.org/software/emacs/)

Official: [git.securityops.co/cristiancmoises/whatsappel](https://git.securityops.co/cristiancmoises/whatsappel)
· Mirror: [Codeberg](https://codeberg.org/berkeley/whatsappel)
· Mirror: [GitHub](https://github.com/cristiancmoises/whatsappel)

</div>

A WhatsApp client for Emacs whose UI/UX follows telega.el. The former Node/Baileys
backend is gone; every line here is **Guile Scheme** and **Emacs Lisp**. The
WhatsApp multi-device protocol itself is delegated to **wuzapi**
(Go/[whatsmeow](https://github.com/tulir/whatsmeow)) over its local REST API —
that protocol (Noise + the Signal double-ratchet + WhatsApp protobufs) has no Guile
implementation and a hand-rolled one would be a homemade-crypto liability. No
JavaScript anywhere.

## Architecture

```
  Emacs (whatsapp.el)                 Guile (whatsappel.scm)             wuzapi (Go/whatsmeow)
 ┌───────────────────────┐  HTTP+tok ┌──────────────────────────┐  HTTP  ┌─────────────────────┐
 │ root chat-list buffer │ ────────► │ /chats /chat /send       │ ─────► │ /chat/send/text|...  │ ──► WhatsApp
 │ per-chat buffers      │ ◄──────── │ /send/{image,video,...}  │ ◄───── │ /chat/download*      │
 │ inline media          │   :7337   │ /download  /connect /qr  │        │ /session/*           │
 │                       │           │ /hook/<token>  ◄─────────┼────────┤ webhook (inbound)    │
 └───────────────────────┘ loopback  └──────────────────────────┘  POST  └─────────────────────┘
```

The bridge keeps a per-chat message store fed by inbound webhooks, records your
sent messages, and unifies 1:1 and group keys so each conversation is one chat.

## Quick start

```
./setup.sh        # checks deps, builds+installs pqenv, makes config, generates a token
# start wuzapi (below), then put its user token in .env (WUZAPI_TOKEN)
make run          # loads .env and starts the bridge
```

`setup.sh` is idempotent — it never overwrites an existing `.env` or PQ identity.
It installs `pqenv` to `~/.local/bin` and creates `~/.config/whatsappel/pq`. A
`Makefile` (`make check|pqenv|install|run|clean`) and a hardened systemd user
unit (`whatsappel.service`) are included. Then load `whatsapp.el` in Emacs (see
[Emacs setup](#emacs-setup)).

## UI/UX (telega-style)

- **Root buffer** (`*WhatsApp*`): the chat list, with unread counts and last
  message. `RET` opens a chat.
- **Chat buffer** (`*WhatsApp: <jid>*`): read-only history above an editable
  input prompt at the bottom. Type and `RET` to send; `C-j` for a newline.
- **Media model, same as telega**: images and stickers render inline; audio,
  video and GIFs open in an external player. Inbound images/stickers are
  downloaded and cached automatically (toggle with `whatsapp-auto-load-images`).

### Keybindings

Root buffer (`whatsapp-root-mode`):

| Key | Action |
|---|---|
| `RET` | open chat at point |
| `n` / `p` | next / previous chat |
| `g` | refresh chat list |
| `j` | jump to a chat by number |
| `q` | bury buffer |

Chat buffer (`whatsapp-chat-mode`):

| Key | Action |
|---|---|
| `RET` | send the input |
| `C-j` | newline in input |
| `C-c C-a` then `i v a f s g` | attach image / video / audio / file / sticker / gif |
| `RET` or `o` on a media line | download + open that media |
| `C-c C-l` | refresh this chat |
| `C-c C-e` | compose + send a post-quantum encrypted message |
| `C-c C-q` | bury buffer |

Global prefix (`whatsapp-prefix-map`, suggested `C-c w`): `w` chat list,
`j` open chat, `c` connect, `s` status, `Q` QR, `k` PQ keygen, `i` PQ import
contact key, `f` show PQ fingerprint.

## Dependencies

- **Guile 3.0** + **guile-json** — the bridge.
- **wuzapi** (Go) — the WhatsApp engine: <https://github.com/asternic/wuzapi>.
- **Emacs ≥ 28** — the client. An external player (`mpv`, `xdg-open`, …) for
  audio/video/GIF.

### Install Guile + guile-json

```
sudo apt install guile-3.0 guile-json     # Debian/Ubuntu
sudo pacman -S guile guile-json           # Arch (guile-json may be AUR)
sudo dnf install guile guile-json         # Fedora
guix shell -m manifest.scm                # Guix
```

### wuzapi

```
git clone https://github.com/asternic/wuzapi.git && cd wuzapi && go build .
WUZAPI_ADMIN_TOKEN=$(openssl rand -hex 16) ./wuzapi -address 127.0.0.1 -port 8080
curl -s -X POST -H "Authorization: $WUZAPI_ADMIN_TOKEN" -H 'Content-Type: application/json' \
     --data '{"name":"me","token":"YOUR_WUZAPI_USER_TOKEN","events":"Message"}' \
     http://127.0.0.1:8080/admin/users
```

> wuzapi's user-auth header is `Token` in its examples but `Authorization` in its
> API reference (varies by build). The bridge defaults to `Token`; override with
> `WUZAPI_TOKEN_HEADER=Authorization` if needed.

## Run the bridge

```
cp env.example .env && $EDITOR .env       # set WHATSAPPEL_TOKEN and WUZAPI_TOKEN
set -a; . ./.env; set +a
guile whatsappel.scm
```

`WHATSAPPEL_TOKEN` and `WUZAPI_TOKEN` are required; the bridge refuses to start
without them. Generate the bridge token with `openssl rand -hex 32`.

| Variable | Default | Meaning |
|---|---|---|
| `WHATSAPPEL_TOKEN` | *(required)* | Emacs↔bridge auth and webhook path secret |
| `WHATSAPPEL_HOST` | `127.0.0.1` | bind address |
| `WHATSAPPEL_PORT` | `7337` | bind port |
| `WHATSAPPEL_PUBLIC_URL` | `http://HOST:PORT` | URL wuzapi calls back for webhooks |
| `WHATSAPPEL_SUBSCRIBE` | `Message` | wuzapi events to subscribe |
| `WHATSAPPEL_CHAT_CAP` | `500` | messages retained per chat |
| `WUZAPI_BASE_URL` | `http://127.0.0.1:8080` | wuzapi base URL |
| `WUZAPI_TOKEN` | *(required)* | wuzapi per-user token |
| `WUZAPI_TOKEN_HEADER` | `Token` | header carrying the user token |

## Autostart

Run wuzapi and the bridge at login so they're always up (the bridge depends on
wuzapi, so start it second / declare the dependency).

**systemd (most distros).** A hardened user unit for the bridge ships as
[`whatsappel.service`](whatsappel.service):

```
cp whatsappel.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now whatsappel
```

Run wuzapi under its own unit (wuzapi ships a `wuzapi.service`), or add one that
`Before=`/`Wants=` the bridge.

**Guix System / Guix Home (shepherd).** Splice the two services in
[`contrib/guix-home-whatsappel.scm`](contrib/guix-home-whatsappel.scm) into the
`services` list of your `home-environment`, then:

```
guix home reconfigure ~/.config/guix/home.scm
herd start whatsappel-bridge        # pulls in wuzapi via (requirement '(wuzapi))
herd status                         # both should be running
```

Both daemons bind to loopback only; secrets are read at runtime from
`~/wuzapi/.env` and `~/whatsappel/.env` (mode `600`), never placed in the store.
The wuzapi session persists under `~/.config/whatsappel/wuzapi-data`, so the phone
link survives restarts — no re-scan.

## Emacs setup

```elisp
(add-to-list 'load-path "/path/to/whatsappel")
(require 'whatsapp)
(require 'whatsapp-org)            ; optional — Org-mode integration
(setq whatsapp-bridge-url   "http://127.0.0.1:7337"
      whatsapp-bridge-token "the-same-value-as-WHATSAPPEL_TOKEN")
(global-set-key (kbd "C-c w") whatsapp-prefix-map)
```

`M-x whatsapp-connect` → `M-x whatsapp-qr` (scan via WhatsApp ▸ Linked devices) →
`M-x whatsapp` (chat list). `M-x whatsapp-toggle-polling` for live updates.

The client's `whatsapp-bridge-token` **must equal** the bridge's `WHATSAPPEL_TOKEN`.
Instead of copying the secret into your config, read it from `.env` at startup so
the two can never drift — this is the recommended wiring:

```elisp
(defun my/whatsapp-load-bridge-env ()
  "Set bridge URL + token from ~/whatsappel/.env (single source of truth)."
  (let ((env (expand-file-name "~/whatsappel/.env")) (host "127.0.0.1") (port "7337"))
    (when (file-readable-p env)
      (with-temp-buffer
        (insert-file-contents env)
        (dolist (pair '(("WHATSAPPEL_HOST" . host) ("WHATSAPPEL_PORT" . port)))
          (goto-char (point-min))
          (when (re-search-forward
                 (format "^[ \t]*\\(?:export[ \t]+\\)?%s=\"?\\([^\"\n]+\\)\"?" (car pair)) nil t)
            (set (cdr pair) (match-string 1))))
        (goto-char (point-min))
        (when (re-search-forward
               "^[ \t]*\\(?:export[ \t]+\\)?WHATSAPPEL_TOKEN=\"?\\([^\"\n]+\\)\"?" nil t)
          (setq whatsapp-bridge-token (match-string 1)))))
    (setq whatsapp-bridge-url (format "http://%s:%s" host port))))
(with-eval-after-load 'whatsapp (my/whatsapp-load-bridge-env))
```

## Org-mode integration (optional)

`whatsapp-org.el` is a separate, opt-in module — the core client never loads Org.
`(require 'whatsapp-org)` adds three seams:

- **`whatsapp:` links.** `org-store-link` (`C-c l`) in a chat buffer or on a
  root-list line yields `[[whatsapp:<jid>][WhatsApp: <name>]]`; following the link
  opens that chat. `C-c C-l` completion offers your known chats.
- **Capture.** `whatsapp-org-capture` (`C-c C-o` in a chat, or `o` in
  `whatsapp-prefix-map`) files the message at point through `org-capture` with the
  sender, an inactive timestamp, a jump-back link, and the text as a quote block.
  PQ-safe: an undecrypted `WAPQ1:` envelope is captured as its placeholder, never
  silently revealed.
- **Send from Org.** `whatsapp-org-mode` adds `C-c C-w s` (send the current
  subtree), `C-c C-w r` (send the region) and `C-c C-w g` (jump entry → chat). The
  target resolves from the entry's inherited `WHATSAPP_JID` property or a prompt;
  every send asks for confirmation first.

## Behaviour notes (honest limits)

- Outbound media is shown in the conversation as a `[kind] caption` placeholder —
  the bytes you sent are not stored back, so they are not re-rendered inline.
- Inbound media rendering is best-effort: the bridge extracts wuzapi's media
  download fields from the webhook event defensively across key-casing variants,
  and always preserves the raw event. If a build's event schema differs, the
  message still appears as a labelled placeholder rather than failing.
- GIFs are sent through the video endpoint (WhatsApp represents GIFs as looping
  MP4 videos).
- The interactive buffer behaviour is not exercised by the build's automated
  tests (headless, no display); the client byte-compiles clean and its pure
  helpers are unit-tested, and the bridge is integration-tested end to end.

## Security model

**Protects**
- The Emacs-facing API requires `X-Whatsappel-Token`; the inbound webhook is
  reachable only at `/hook/<token>`. Token comparison is constant-time. Bridge
  and wuzapi both bind to loopback. Transport inherits WhatsApp's own E2EE.

**Does NOT protect against**
- A compromised host: the bridge and wuzapi see plaintext locally.
- wuzapi's on-disk session is a linked-device credential — anyone who can read it
  can impersonate your WhatsApp. Restrict its directory; use full-disk encryption.
- Plaintext secrets in `.env` and Emacs config — protect both files.
- Metadata (who you message, when, group membership) — visible to Meta.
- Account bans: wuzapi/whatsmeow is an unofficial client; use may violate
  WhatsApp's Terms of Service.

## Post-quantum messages (opt-in, 1:1)

An optional end-to-end **post-quantum envelope** rides inside a normal WhatsApp
text message as a `WAPQ1:` blob, built by the bundled [`pqenv`](pqenv/README.md)
tool (ML-KEM-1024 + ML-DSA-87 + ChaCha20-Poly1305, HKDF-SHA256; primitives from
the formally verified libcrux). It protects content **only between two whatsappel
users who have exchanged public keys** — to any normal contact it is an opaque
blob, and it does not hide metadata from Meta. It is not "post-quantum WhatsApp."

Usage:

1. `C-c w k` (`whatsapp-pq-keygen`) — once, to create your identity. Share
   `~/.config/whatsappel/pq/identity.public` with your contact.
2. `C-c w i` (`whatsapp-pq-import-contact`) — import their `.public` and associate
   it with the chat. Verify the printed fingerprint out of band. The fingerprint is
   pinned on first import (TOFU): a later import of a *different* key for the same
   chat is refused — a silent change can mean key substitution — unless you re-verify
   and override with `C-u C-c w i`.
3. In the chat, type and press `C-c C-e` to send encrypted. Inbound `WAPQ1:`
   messages are verified and decrypted on view, shown with a `[PQ]` marker;
   messages outside the freshness window show `[encrypted — stale/replayed:
   outside freshness window]` and other failures show `[encrypted — decrypt/verify
   FAILED]`. The window is `whatsapp-pq-max-age` (default 7 days; 0 disables it).

Limits (carried from the `pqenv` threat model): 1:1 only (group keying is future
work); the in-chat `C-c C-e` path uses the single-shot envelope, which has **no
forward secrecy** (long-term KEM identity keys). A forward-secure session layer
(WAPQR: ephemeral-prekey bootstrap + symmetric ratchet) now exists in `pqenv`
(`ratchet-prekey`/`-init`/`-accept`/`-send`/`-recv`); wiring stateful per-chat
sessions into this client is the next step. Replay of *old* captured envelopes is
blocked by the freshness window on view; per-message replay-on-receive across
restarts is not wired. See [pqenv/README.md](pqenv/README.md) for the full threat
model, wire formats, and the WAPQR handshake.

## Repositories

| Role | URL |
|---|---|
| **Official** (Forgejo) | <https://git.securityops.co/cristiancmoises/whatsappel> |
| Mirror (Codeberg) | <https://codeberg.org/berkeley/whatsappel> |
| Mirror (GitHub) | <https://github.com/cristiancmoises/whatsappel> |

Issues and pull requests are tracked on the Forgejo repo; the mirrors are
read-only copies kept in sync at each release.

## Author

Cristian Cezar Moisés — <https://securityops.co>

## License

[`AGPL-3.0-only`](LICENSE). A network-facing bridge is the textbook AGPL case: if
you run a modified version as a service, the AGPL requires you to offer that
modified source to its users. The bundled `pqenv` crate and the Guile bridge carry
the same `SPDX-License-Identifier: AGPL-3.0-only` headers.
