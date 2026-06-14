# WhatsApp.el — Full WhatsApp Client for Emacs

A complete WhatsApp client inside Emacs, powered by a local [Baileys](https://github.com/WhiskeySockets/Baileys) bridge server. Text, images, videos, audio, voice messages, documents, locations, polls, contact cards — groups, contacts, pins, archives, stars, search — all from your editor.

**Fully local. No cloud relay. No middlemen. Your session stays on your machine.**

## Screenshots

### Chat List
```
 📱 WhatsApp  (? help · h actions)
 ● ── ── Name                     Last Message                           Time
 ●CM 📌  Cristian Moisés      (2) Hey, did you see the latest ...       14:32
 ●AR     Alice Rodriguez          Sure, I'll send it over                14:28
 ○JD     John Doe                 📷 Image 1.2MB                        13:15
   👥    Dev Team             (5) Bob: The build is passing now          12:44
 ○ML     Mom ❤️                   Call me when you can                   11:02
   👥 📌 Security Ops             Cristian: New release pushed           09:30
```

### Chat Buffer (with inline compose)
```
 💬 Alice Rodriguez ● online
─────────────── Today ───────────────
Alice Rodriguez
Hey, check out this article  14:25

  ┃ Hey, check out this article
  I saw it! The part about post-quantum...  14:26 ✓✓
  🔗 Post-Quantum Cryptography Standards
     NIST finalizes three algorithms for...

Alice Rodriguez
  *Exactly!* The _ML-KEM_ section is great  14:27
   👍 2   🔥

  Yeah, I'm implementing ML-KEM-768 in Zupt  14:28 ✓✓
  (edited)

Alice Rodriguez
  📷 Image 245KB
  [m] Screenshot of the benchmark results  14:30

  Nice numbers! 🚀  14:31 ✓✓

─── compose (RET send · C-j newline · TAB focus · h menu) ───
→ |
```

### Contact Info
```
 CM  Cristian Moisés

 Phone: +5554999998888
 Push Name: Cristian
 About: In Code We Trust.
 Status: Online

 ─── Actions ───
  o Open chat  · w Copy phone  · q Close
```

## Architecture

```
┌──────────────┐    WebSocket     ┌──────────────┐    WhatsApp Web    ┌──────────┐
│   Emacs      │◄────────────────►│  server.js   │◄──────────────────►│ WhatsApp │
│  whatsapp.el │    REST (44 ep)  │  (Baileys)   │    (Signal Proto)  │ Servers  │
└──────────────┘                  └──────────────┘                    └──────────┘
```

## Features

### Core Messaging
- Inline compose area at bottom of chat buffer (type directly, RET sends)
- WhatsApp formatting rendered: **\*bold\***, _\_italic\__, ~\~strike\~~, \`\`\`code\`\`\`
- Org-style markup auto-converted before sending
- Reply/quote, edit, delete, forward with contact completion
- Reactions with emoji picker (40 common + free input)
- Clickable URLs with hover preview
- Star/unstar messages, starred browser
- Message search (global `S` and in-chat `/`)
- Smart scroll: new messages don't yank you away when reading history
- Draft persistence across buffer switches

### Media
- Send any file type, voice recording (`v` toggle, sox/ffmpeg/arecord)
- Receive with metadata (size, duration, filename)
- Download (`m`), inline image display, audio playback (`C-c C-a` via mpv/emms)
- Send locations, polls, contact cards

### Chat & Group Management
- Pin/mute/archive/delete chats
- Create groups, add/remove members, leave, invite links
- Full contact and group info buffers
- Mark all read, toggle archive view

### Status/Stories
- View recent status updates from contacts (`W`)

### Real-Time
- WebSocket push — no polling
- Typing indicators (send + receive), presence (●/○)
- Read receipts: ⏳ → ✓ → ✓✓ → ✓✓ (blue)
- "↓ N new" indicator when scrolled up
- Unread separator bar, mode-line `WA[3]`
- Smart dates: "Today", "Yesterday", weekday names

### Productivity
- **Quick reply templates**: `C-c C-r` sends from customizable preset list
- **Chat filters**: `1` unread, `2` groups, `3` contacts, `0` clear
- **Message yank**: `C-c C-y` pastes last received message text
- **Notification sound**: optional audio alert on new messages
- **Auto-away**: automatic reply when Emacs idle (configurable message + timeout)

### Notifications
- D-Bus (Linux), osascript (macOS), alert.el, or custom function
- Muted chats skip notifications

### Integration
- **Embark**: context actions on messages
- **Bookmark**: `C-x r m` / `C-x r b` for chats
- **Imenu**: navigate by date headers
- **Actions menu**: `h` for discoverable commands
- **Context menu**: right-click in graphical Emacs
- Chat export to **text** or **Org-mode**
- Chat statistics (`I`)

### Security
- Optional **bearer token auth** for REST + WebSocket
- Optional **rate limiting** (requests/minute)
- **systemd hardening**: NoNewPrivileges, ProtectHome
- Docker isolation with named volumes

## Requirements

- **Node.js ≥ 18** + npm
- **Emacs ≥ 28.1**
- **websocket.el** (MELPA)
- **curl** (file uploads)
- Optional: `sox`/`ffmpeg` (voice), `mpv` (audio playback)

## Quick Start

### One-Command Install

```bash
git clone https://codeberg.org/berkeley/whatsappel.git
cd whatsappel
./install.sh            # or: ./install.sh --systemd
```

### Manual Install

```bash
# Server
npm install
node server.js          # scan QR code

# Emacs
cp whatsapp.el ~/.emacs.d/lisp/
```

### Docker

```bash
docker compose up -d
docker compose logs -f   # scan QR here
```

### Connect in Emacs

```
M-x whatsapp-connect
```

## Example Configuration

### Minimal

```elisp
(use-package websocket :ensure t)
(use-package whatsapp
  :load-path "~/.emacs.d/lisp/"
  :commands (whatsapp-connect))
```

### Recommended

```elisp
(use-package websocket :ensure t)
(use-package whatsapp
  :load-path "~/.emacs.d/lisp/"
  :commands (whatsapp-connect whatsapp-status)
  :bind ("C-c w" . whatsapp-connect)
  :custom
  (whatsapp-server-host "localhost")
  (whatsapp-server-port 3000)
  (whatsapp-ws-port 3001)
  (whatsapp-media-directory "~/whatsapp-media/")
  (whatsapp-render-formatting t)
  (whatsapp-clickable-urls t)
  (whatsapp-inline-images t)
  (whatsapp-show-link-previews t)
  (whatsapp-auto-read t)
  (whatsapp-typing-indicator t))
```

### With Auth + Notifications

```elisp
(use-package whatsapp
  :load-path "~/.emacs.d/lisp/"
  :commands (whatsapp-connect)
  :custom
  (whatsapp-api-token "my-secret-token")  ; match WAEL_API_TOKEN
  (whatsapp-notification-function
   (lambda (sender text jid)
     (alert text :title (format "WA: %s" sender) :category 'whatsapp)))
  (whatsapp-relative-timestamps t)
  (whatsapp-voice-record-command "ffmpeg")
  (whatsapp-audio-player "mpv"))
```

### With straight.el

```elisp
(straight-use-package
 '(whatsapp :type git :host nil
            :repo "https://codeberg.org/berkeley/whatsappel.git"
            :files ("whatsapp.el")))
```

## Keybindings

### Chat List (`*WhatsApp*`)

| Key | Action | Key | Action |
|-----|--------|-----|--------|
| `RET` | Open chat | `A` | Archive toggle |
| `c` | New message | `P` | Pin/unpin |
| `C` | Contacts | `M` | Mute/unmute |
| `g` | Refresh | `D` | Delete chat |
| `s` | Filter | `R` | Mark all read |
| `S` | Search msgs | `TAB` | Toggle archive |
| `G` | Create group | `*` | Starred msgs |
| `W` | Status/stories | `h` | Actions menu |
| `q` | Bury | `Q` | Disconnect |

### Chat Buffer

| Key | Action | Key | Action |
|-----|--------|-----|--------|
| `RET` | Send (compose) | `a` | Attach file |
| `TAB` | Focus compose | `v` | Voice record |
| `C-j` | Newline | `m` | Download media |
| `C-c C-e` | Multi-line | `C-c C-a` | Play audio |
| `r` | Reply | `w` | Copy text |
| `C-c C-k` | Cancel reply | `*` | Star/unstar |
| `e` | React (emoji) | `/` | Search in chat |
| `E` | Edit own | `I` | Chat stats |
| `d` | Delete | `x` | Export chat |
| `f` | Forward | `L` | Location |
| `i` | Info | `C-c C-p` | Poll |
| `n`/`p` | Navigate | `C-c C-v` | Contact card |
| `N` | Unread sep | `G` | Scroll bottom |
| `C-c C-h` | Load older | `h` | Actions menu |

## Configuration

All via `M-x customize-group RET whatsapp`.

| Variable | Default | Description |
|----------|---------|-------------|
| `whatsapp-server-host` | `localhost` | Bridge hostname |
| `whatsapp-server-port` | `3000` | HTTP port |
| `whatsapp-ws-port` | `3001` | WebSocket port |
| `whatsapp-api-token` | `""` | Auth token (empty=none) |
| `whatsapp-history-fetch-count` | `50` | Messages per load |
| `whatsapp-auto-read` | `t` | Auto-mark read |
| `whatsapp-typing-indicator` | `t` | Send typing |
| `whatsapp-typing-debounce` | `2.0` | Typing debounce (s) |
| `whatsapp-time-format` | `%H:%M` | Timestamp format |
| `whatsapp-date-format` | `%Y-%m-%d %a` | Date format |
| `whatsapp-media-directory` | `~/.emacs.d/whatsapp-media` | Media storage |
| `whatsapp-render-formatting` | `t` | Render *bold* etc |
| `whatsapp-clickable-urls` | `t` | Clickable links |
| `whatsapp-relative-timestamps` | `nil` | "2m ago" style |
| `whatsapp-show-archive` | `nil` | Show archived |
| `whatsapp-show-link-previews` | `t` | URL previews |
| `whatsapp-show-profile-pics` | `nil` | Profile photos |
| `whatsapp-sender-colors` | 8 colors | Group name colors |
| `whatsapp-voice-record-command` | `sox` | Voice recorder |
| `whatsapp-audio-player` | `mpv` | Audio playback |
| `whatsapp-inline-images` | `t` | Inline images |
| `whatsapp-inline-image-max-width` | `300` | Image max width |
| `whatsapp-export-directory` | `~/.emacs.d/whatsapp-exports` | Export dir |
| `whatsapp-convert-org-markup` | `t` | Org→WA formatting |

### Server Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `WAEL_PORT` | `3000` | HTTP port |
| `WAEL_WS_PORT` | `3001` | WebSocket port |
| `WAEL_AUTH_DIR` | `./auth_info` | Session storage |
| `WAEL_MEDIA_DIR` | `./media` | Upload temp |
| `WAEL_STORE_FILE` | `./store.json` | Data store |
| `WAEL_LOG_LEVEL` | `warn` | pino log level |
| `WAEL_API_TOKEN` | (none) | Bearer auth token |
| `WAEL_RATE_LIMIT` | `0` | Requests/min (0=off) |

## Deployment

### Docker

```bash
docker compose up -d     # start
docker compose logs -f   # QR + logs
docker compose down      # stop
```

### Systemd

```bash
make install-service
systemctl --user enable --now whatsappel
journalctl --user -u whatsappel -f
```

## FAQ

**Can I use this on a remote server?**
Yes. Run `server.js` on the remote host, SSH tunnel the ports: `ssh -L 3000:localhost:3000 -L 3001:localhost:3001 host`. Set `WAEL_API_TOKEN` for auth.

**Does this work in terminal Emacs?**
Yes. Everything works except inline image display and the right-click context menu. Profile pictures fall back to text initials.

**Will my phone need to stay online?**
No. Baileys uses the multi-device protocol. Once paired, the session is independent. Your phone can be offline.

**How much memory does the server use?**
~50-80MB with a few hundred chats. Messages are capped at 500 per chat in memory. The store.json file handles persistence.

**Can multiple Emacs instances connect?**
Yes. The WebSocket server broadcasts to all connected clients. Multiple Emacs frames can view different chats simultaneously.

**Is end-to-end encryption preserved?**
Yes. Baileys implements the Signal Protocol. Encryption/decryption happens in the server process. Messages are decrypted in memory only. The REST API sends plaintext over localhost.

**What about WhatsApp's Terms of Service?**
Baileys is an unofficial library. Use at your own discretion. WhatsApp may ban accounts using unofficial clients, though this is rare for personal use.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Connection failed | `node server.js` running? Ports match? |
| QR expired | Restart server |
| No messages | `M-x whatsapp-status` → `M-x whatsapp-reconnect` |
| Media "expired" | Server caches ~200 raw messages; reopen chat |
| Voice fails | `apt install sox` / `brew install sox` |
| Node version | ≥18 required (`node --version`) |
| Port conflict | `WAEL_PORT=3100 WAEL_WS_PORT=3101 node server.js` |
| Session lost | Delete `auth_info/`, re-scan QR |
| Auth 401 | Token mismatch between server and Emacs config |
| Rate limited 429 | Increase `WAEL_RATE_LIMIT` or set to 0 |

## Development

```bash
make              # byte-compile
make test         # syntax checks
make test-server  # endpoint tests (server must be running)
make lint         # checkdoc
make docker-build # build image
```

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Build Stats

| Component | Lines | Metrics |
|-----------|-------|---------|
| server.js | 1,651 | 44 endpoints, auth, rate limit, WS heartbeat |
| whatsapp.el | 1,414 | 70 commands, 80 keybinds, 36 faces, 32 config vars |
| test/test-server.js | 240 | 27/27 pass against live server |
| openapi.yaml | 280 | Full REST API spec (OpenAPI 3.1) |
| Infrastructure | 259 | Dockerfile, compose, systemd, Makefile, installer |
| Documentation | 660 | README, CHANGELOG, CONTRIBUTING, LICENSE |
| **Total** | **~4,500** | **16 files** |

## License

GPL-3.0 — see [LICENSE](LICENSE).
