# Changelog

All notable changes to WhatsApp.el are documented here. This project adheres to
[Semantic Versioning](https://semver.org/).

## [3.0.1] — 2026-06-16

### Added
- **History import.** The bridge now pulls existing conversations from wuzapi on
  startup (and on demand via `POST /sync`) instead of only showing messages that
  arrive live: it reads `GET /chat/history?chat_jid=index` for the chat list and
  per-chat history, and resolves display names from `/user/contacts` and
  `/group/list`. So after linking a device, the chat list and past messages appear
  immediately. Requires wuzapi history retention enabled for the user
  (`POST /session/history {"history": N}`); tune the per-chat depth with
  `WHATSAPPEL_HISTORY` (default 200). Note: chats addressed by WhatsApp's `@lid`
  (anonymous linked-ID) show their id until a live message supplies a `PushName`,
  since wuzapi's history rows and contact map don't carry the LID↔phone link.

- **`@lid` name resolution.** Chats addressed by WhatsApp's anonymous linked-ID
  (`@lid`) carry no phone number in history. Setting `WHATSAPPEL_LIDMAP_DB` to
  wuzapi's `main.db` lets the bridge read its `whatsmeow_lid_map` (read-only, via
  `sqlite3`) to map `@lid` to a phone number, then resolve a saved contact name —
  or fall back to showing the real phone number. On a real account this lifted
  chat-name coverage from roughly 19% to 98%.

### Documentation
- **Autostart guide** in the README covering both systemd (`whatsappel.service`)
  and Guix System / Guix Home (shepherd), including the bridge→wuzapi dependency,
  loopback binding, runtime-only secrets and a persistent wuzapi session.
- Recommended Emacs wiring that reads `whatsapp-bridge-token` (and host/port) from
  `~/whatsappel/.env` at startup, so the client and bridge tokens can never drift.
- Documented the end-to-end bring-up (wuzapi build/run → user token → bridge → QR).

### Added
- `contrib/guix-home-whatsappel.scm` — ready-to-splice Guix Home shepherd services
  that autostart wuzapi + the Guile bridge at login (the shepherd counterpart of
  the bundled systemd unit).

## [3.0.0] — 2026-06-16

A ground-up rewrite. The Node/Baileys bridge is **gone**; there is no JavaScript
anywhere. The backend is now **Guile Scheme** (`whatsappel.scm`) talking to
**wuzapi** (Go/whatsmeow) over its local REST API, and the client is **Emacs Lisp**.

### Changed (breaking)
- **New architecture: Emacs ⇄ Guile bridge ⇄ wuzapi.** The bridge is a single
  Guile program on `127.0.0.1:7337`; the WhatsApp multi-device protocol (Noise +
  Signal double-ratchet + protobufs) is delegated to wuzapi rather than reimplemented.
- **Client rewritten** as a lean, telega-style `whatsapp.el` (`whatsapp-bridge-url`
  / `whatsapp-bridge-token`): root chat-list buffer, per-chat message buffers with
  a bottom input prompt, inline images/stickers, external player for audio/video/GIF.
- **Removed** `server.js`, `package.json`, `package-lock.json`, the Node test
  suite, the Baileys bridge docs, the Docker/compose files and the OpenAPI spec —
  none apply to the Guile backend.
- **License** moved to `AGPL-3.0-only` (a network-facing bridge is the textbook
  AGPL case); all source files carry SPDX headers.

### Added
- **`pqenv`** — a bundled Rust crate (`#![forbid(unsafe_code)]`) implementing an
  opt-in, 1:1 **post-quantum message envelope** (`WAPQ1:`): ML-KEM-1024 +
  ML-DSA-87 + ChaCha20-Poly1305 + HKDF-SHA256, primitives from the formally
  verified libcrux. In-chat keygen (`C-c w k`), TOFU contact-key import
  (`C-c w i`), fingerprint display (`C-c w f`) and encrypted send (`C-c C-e`), with
  a freshness/replay window on view. Includes an experimental forward-secure
  ratchet (WAPQR) at the CLI/library level.
- **`whatsapp-org.el`** — optional Org-mode integration (loaded only on request):
  a `whatsapp:` Org link type, `org-capture` of the message at point (PQ-safe), and
  send-from-Org (`C-c C-w s/r`, `WHATSAPP_JID` property targeting).
- **Packaging & ops**: idempotent `setup.sh`, a `Makefile` (`check`/`pqenv`/
  `install`/`run`), a Guix `manifest.scm`, an `env.example`, and a hardened
  `whatsappel.service` systemd user unit.

### Security
- Emacs-facing API and inbound webhook are gated by a constant-time token check;
  bridge and wuzapi bind to loopback only. Documented threat model for both the
  bridge and the post-quantum envelope (see README and `pqenv/README.md`).

## [2.7.2] — 2026-06-13

### Added
- **LID support**: resolve WhatsApp's new `@lid` (anonymous linked-ID) addressing to
  real names + phone numbers via a bidirectional LID↔phone map (contacts, message
  `senderPn`, and group participants). Group subjects are backfilled on connect.
- **Telega-style input**: the chat buffer is now a real message box — click a chat
  and just start typing; `RET` sends, `C-j`/`S-RET` for a newline. All actions moved
  under a `C-c` prefix (`C-c h` opens the action menu).
- **Media**: inline images, looping inline GIFs/animated stickers, click-to-play
  video/voice (mpv), and improved voice recording (`C-c v` toggle, `C-u C-c v` cancel).
- Click-to-open chats (mouse-1) with hover highlight; empty-state guidance.
- On-demand history paging (`C-c <` / `C-c C-h`) and message persistence across restarts.

### Fixed
- Names no longer show the user's own number; recipient picker is never empty.
- Read/edit/delete use proper message keys (work in groups & `@lid` chats).
- Atomic store writes, debounced saves/broadcasts, async (non-blocking) avatars/media.

### Changed
- Canonical project URLs now point to the official Forgejo repo
  (`git.securityops.co/cristiancmoises/whatsappel`); Codeberg is co-official and
  GitHub is a read-only mirror. Updated `whatsapp.el` header, `package.json`
  (bumped to 2.7.2, with `homepage`/`repository`/`bugs`), and `whatsappel.service`.

### Documentation
- Rewrote `README.md`: project logo, accurate feature list, architecture diagram,
  install/usage guides, full keybinding & configuration reference, privacy notes,
  an author's note, and a Repositories (official vs mirror) section.
- Shipped a ready-to-copy example `init.el` and kept the full bridge/API reference
  under `docs/BRIDGE.md`.

## [2.7.0] — 2026-05-25

### Added
- Quick reply templates (`C-c C-r`) with customizable `whatsapp-quick-replies` alist
- Notification sound support (`whatsapp-notification-sound`)
- Auto-away: automatic reply when Emacs idle (`whatsapp-auto-away`, `whatsapp-auto-away-idle`)
- Chat filter presets: `1` unread, `2` groups, `3` contacts, `0` clear
- Message yank: `C-c C-y` inserts last received message text
- Connection health monitor with auto-reconnect on server restart
- Connection state hook (`whatsapp-connection-hook`)
- API bearer token auth for REST + WebSocket (`whatsapp-api-token`)
- Server rate limiting (`WAEL_RATE_LIMIT`)
- WebSocket heartbeat (ping/pong, 30s interval)
- Auto-save store every 5 minutes with reactions pruning
- OpenAPI 3.1 spec (`openapi.yaml`)
- Server boot verification: 27/27 tests pass

### Fixed
- Emacs 28 compat: `time-subtract` with `(current-time)` instead of `nil`
- Org export: eliminated nil insertion from `when` in `insert` call
- Compose area: setup in history callback instead of fragile 0.5s timer
- Starred messages persisted to `store.json` and restored on load
- Removed Baileys deprecated `printQRInTerminal` option (clean boot)

## [2.6.0] — 2026-05-25

### Added
- Status/stories viewer (`W` in chat list)
- In-chat search (`/` in chat buffer)
- Smart date labels: "Today", "Yesterday", weekday names
- Notification filtering: muted chats skip desktop notifications
- Chat statistics (`I`): message counts, media counts, per-sender breakdown
- Right-click context menu in graphical Emacs (reply, react, copy, forward, star, edit, delete)
- Docker deployment: Dockerfile + docker-compose.yml
- Systemd user service: `whatsappel.service`
- Makefile: byte-compile, lint, install, docker-build, docker-run
- Server test suite: `test/test-server.js` (endpoint shape + validation tests)

### Server
- `GET /status` — recent status updates from contacts
- `GET /messages/search/chat/:jid` — search within a single chat
- `GET /chats/:jid/stats` — chat statistics
- Status broadcast capture (no longer discarded)

## [2.5.0] — 2026-05-25

### Added
- Full contact info buffer for 1:1 chats (name, phone, about, status, actions)
- Clickable search results (RET opens the chat)
- Org-mode export format (`x` → choose text or org)
- Profile picture download and display in chat list (optional)
- Link preview rendering (URL title + description below messages)
- Audio playback (`C-c C-a` via mpv or emms)
- Chat export to text file (`x`)
- Draft persistence (compose text saved on buffer switch)
- Compose-area typing indicators (post-self-insert-hook)

### Server
- `GET /chats/:jid/export` — chat export endpoint (text/json)
- `GET /contacts/:jid` enriched with status text and profile pic URL
- Link preview data in message normalization

## [2.4.0] — 2026-05-25

### Added
- Inline compose area at bottom of chat buffer (type directly, RET sends)
- Smart scroll: no auto-scroll when reading history, "↓ N new" indicator
- Reply-in-place: `r` sets context, compose sends with quote
- Emoji picker with 40 common emoji + free input
- Actions menu (`h`) with read-char-choice dispatch
- Auto-fetch contacts on connection
- Full-date tooltip on timestamp hover (help-echo)

### Changed
- `whatsapp-chat-mode` no longer inherits `special-mode` (required for inline compose)

## [2.3.0] — 2026-05-25

### Added
- WhatsApp text formatting rendering (*bold*, _italic_, ~strike~, ```code```)
- Clickable URLs with browse-url
- Sender color hashing for group chats (8-color palette)
- Copy message text (`w`)
- Star/unstar messages (`*`), starred messages browser
- Relative timestamps option
- Profile initials in chat list
- Archive view toggle (`TAB`)
- Mark all chats read (`R`)
- Embark integration (context actions keymap)
- Bookmark support for chat buffers
- Imenu support (date header navigation)

### Server
- `POST /messages/star`, `GET /messages/starred`
- `POST /chats/read-all`
- `GET /contacts/avatars` (batch profile pic URLs)

## [2.2.0] — 2026-05-25

### Added
- Full media pipeline: send/receive images, video, audio, documents
- Voice recording and sending (`v` toggle, sox/ffmpeg/arecord backends)
- Media download with inline image display (`m`)
- Contact browser with search (`C`)
- Group management: create, info, add/remove members, leave, invite link
- Chat management: archive, pin, mute, delete
- Send location, polls, contact cards
- Multi-line compose buffer (`C-c C-e`)

### Server
- Media download endpoint with `downloadMediaMessage`
- Send location, contact, poll, forward endpoints
- Full group CRUD endpoints
- Chat archive/mute/pin/delete endpoints
- Contact avatar endpoint

## [2.1.0] — 2026-05-25

### Added
- Reactions display with emoji + count badges
- Typing indicators (send and receive, debounced)
- Presence tracking: online/offline in chat list and header
- Unread message separator bar
- Contact completion for send/forward
- Message search across all chats (`S`)
- Org-style markup conversion (/italic/ → _italic_, =code= → ```code```)
- Desktop notifications (D-Bus, macOS, alert.el fallback)

### Server
- Reaction aggregation store
- Presence tracking and endpoint
- Message edit endpoint

## [2.0.0] — 2026-05-25

### Added
- Complete rewrite from scratch
- Node.js bridge server with Baileys, REST API + WebSocket
- Emacs client: chat list (tabulated-list-mode), chat buffers (ewoc)
- Text send/receive, reply/quote, edit, delete, forward
- Message history loading with pagination
- Real-time updates via WebSocket (13 event types)
- QR code display for pairing
- Mode-line unread count
- 36 theme-safe faces
- Auto-reconnect with exponential backoff
