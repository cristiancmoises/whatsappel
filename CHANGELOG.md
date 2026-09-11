# Changelog

## 3.2.0-rc17 — README / documentation refresh

- Reworked English and PT-BR README files around the current native Emacs workflow.
- Added all five user-supplied application screenshots to the public documentation.
- Preserved three screenshots byte-for-byte; cropped only the bottom modeline/footer from two conversation screenshots as explicitly requested.
- Added screenshot provenance notes and four-forge publication tooling.
- Application behavior remains RC17; this documentation refresh does not claim new delivery, profile, presence, Pale, or security behavior.

# 3.2.0-rc17 — focused send-failure guard

- Check that a failed response body is a proper list before reading its error field.
- Handle invalid-JSON and transport sentinels as unconfirmed outcomes, not callback exceptions.
- Keep the original send-failure, late-account, draft/reply and recipient tests unchanged.
- Add ten native regressions for immediate/deferred failures, newer edits, reply/undo
  preservation, allowlisted/redacted errors, callback ownership, no resend and valid acceptance.
- Preserve the verified-send route, recipient checks, bridge implementation, photos,
  line-cleanup behavior and two-full-audit activation gate. No live delivery claim.

# 3.2.0-rc16 — 2026-09-10

- Require recipient-contract acknowledgement on normal text sends, without retry.
- Classify provider failures with bounded, redacted local messages.
- Retain explicit own history rows with no embedded message metadata.
- Preserve profile-worker failure categories on unsuccessful exits; selected retry.
- Correct About phone JIDs, preserve LIDs, keep CDN/decoder limits.
- Remove current-buffer global hl-line overlay and explicit row-face decorations.
- Add worker/HTTP, Guile, ERT regressions; retain mandatory double native gate.
- No live delivery, native Pale integration, or measured UI speedup claimed.

# 3.2.0-rc15 — verified activation and accepted-send recovery

- Preserve accepted status if starting its history refresh raises an exception;
  retain newer drafts, account warnings, provider IDs and no automatic resend.
- Add optional, strictly verified local Shepherd activation after two full audits
  and post-install payload checks; read-only status mode and private phase report.
- Probe live transport independent of health advertisement; conflicting versions
  cannot confirm activation. Registration remains distinct from delivery.
- Add real Python process/HTTP/filesystem/socket tests and four native ERT cases.
- Keep existing init, local sessions, older failure tests and cumulative anchors.
  No new Pale binding, GUI performance result or live delivery claim.

# RC14 — 2026-09-10

- Restore the visible error state for a late send response after an account or
  conversation change; keep the original draft and mark the attempt unconfirmed.
- Preserve the original failing RC3 ERT case unchanged; add six native regressions
  for changed tokens/URLs, draft/reply/undo preservation, duplicate responses,
  callback-buffer ownership, no resend, and normal-account acceptance.
- Keep LID targeting, local notes, line cleanup, strict acceptance and the original
  two-full-audit installer gate. No provider, profile or cryptographic behavior change.
- Restart the existing service only after a successful install and hash verification
  in the supplied command. Failed audits must not trigger a service restart.

# RC13 — 2026-09-10

- Keep @lid recipient identities intact and recompute the selected text target.
- Add one bounded, account-scoped local send-note overlay with strict acceptance,
  provider-ID reconciliation and explicit uncertain-outcome dismissal.
- Suppress app-local decorative underline/overline/box/hl-line styles and wrap actions.
- Correct the retained ERT mock for the RC11 /send worker payload contract.
- Add native identity/outbox/UI and bridge receipt/storage regressions plus real
  worker HTTP namespace tests. Native/live results remain separately reported.
- Use unique RC13 artifacts based on RC11; do not overwrite incomplete RC12 work.

# 3.2.0-rc11 — transport and delivery candidate

- Require unambiguous upstream message IDs; no automatic resend on uncertainty.
- Parse direct/form/JSON jsonData and binary multipart metadata; reject duplicates.
- Preserve ordinary ephemeral/document-caption media without unwrapping view-once.
- Add redacted read-only connection check and explicitly confirmed callback repair.
- Preserve webhook subscriptions; receipt labels do not invent recipient delivery.
- Retry failed visible images explicitly; add bounded native GIF viewer.
- Separate client origins from provider callback URLs in launcher and diagnostics.
- Pale preference is present but native Pale playback remains unavailable; mpv is
  explicit only. No claim of completed Pale integration or live acceptance.
- Add subprocess/loopback Python tests, Guile HTTP tests, ERT cases and audit gate.

# 3.2.0-rc10 — 2026-09-10

- Fix profile validation before cache filtering: invalid groups/events no longer
  receive HTTP 200 merely because the contact has not been cached.
- Preserve valid unknown-event suppression, group photos and existing message state.
- Keep the failing RC9 assertion and add 12 native regression methods.
- Print bounded Python failure identifiers; add 10 diagnostic safety tests.
- Retain guarded cumulative Guix update and four-remote publication workflows.
- Native and live release status is documented in AUDIT-3.2.0-rc10.md.

# 3.2.0-rc9 — profile workspace candidate (2026-09-10)

- Add scoped native cyan/current-theme faces, reserved avatar gutter, contact-info
  and settings panels, font controls, emoji insertion and redacted diagnostics.
- Add a dedicated bounded profile worker: authenticated job submission, exact-host
  HTTPS photo fetching with vetted DNS pinning, limited FFmpeg thumbnails and no
  credential forwarding or redirects. Photos and metadata remain memory-only.
- Add authenticated profile snapshots, two-worker metadata jobs, opt-in presence
  subscription, typed observed Presence/ChatPresence/Picture handling, epoch and
  picture-revision invalidation. Keep transcript revisions and unread state separate.
- Preserve RC8 compose-first contact selection, explicit async decryption, drafts,
  original media and existing two-pass guarded update/rollback/publication flow.
- Native tests and screenshots are supplied but not asserted executed where tools
  are absent. No remote Idle inference, stories, self-online announcement, provider
  configuration changes, live deployment or new cryptographic guarantee.

# 3.2.0-rc8 — contact selection (2026-09-10)

Composer-first deferred refresh; bounded original-preserving text previews; no new image decoding or synchronous PQ in transcript insertion; scoped asynchronous explicit decryption; wall-clock scroll scheduling and content-free loaded-client diagnostics. Native/live acceptance remains required.

## 3.2.0-rc7 — 2026-09-10

- Fix mixed-source launcher account selection: external URL and token are chosen as a pair.
- Add one-command existing-source Guix updates with two full audits and desktop registration.
- Add explicit complete-source fresh installation with audited, atomic no-replace publication.
- Add a commit-baseline check, full-scope publication audits and a retry-only four-remote command.
- Replace stale README release layers with current English/Portuguese guides; archive history.
- Preserve RC6 history-button/SRFI-64 fixes, worker bounds, no-resend rules and local state.
- Candidate: native and live acceptance remains distinct from local Python/transaction tests.

# 3.2.0-rc6 — 2026-09-10

- Fix obsolete history-button assertion by activating the real button.
- Correct named SRFI-64 test-error form; extend configuration boundary coverage.
- Enumerate visible windows instead of scanning all Emacs buffers for polling.
- Keep per-buffer backoff and isolate synchronous refresh exceptions.
- Require private bounded descriptor-based launcher configuration reads.
- Print native failed-test IDs; summarize audits without rerunning them.
- Retain two-pass installation and cumulative content anchors.
- No bridge/wuzapi/PQ implementation changes or production writes.

# 3.2.0-rc5 — 2026-09-10

- Share bounded strict JSON/deadline primitives across read and upload workers.
  Reject ambiguous duplicate acknowledgements, nonfinite numbers and lone Unicode
  surrogates; keep valid scalar Unicode and original-media handling intact.
- Bound upload POST/reply wall time on the owned POSIX main-thread worker; a lost
  or malformed acknowledgement remains uncertain, with no automatic resend.
- Forward only fully validated raw read JSON into the worker envelope, avoiding
  a second serialization. Stream SHA-256 inputs in fixed-size blocks. Isolated
  microbenchmarks do not measure complete WhatsApp loading or delivery.
- Record unittest successes/skips/errors directly. Empty, incomplete or conflicting
  receipts cannot pass. Bound audit logs and runtime; clean up owned POSIX groups.
- Require distinct full receipts, exact gate sets and unchanged pre/post code hashes
  for installation. Recheck source/bundle/documents after both passes; install
  immutable candidate bytes rather than rereading a mutable download directory.
- Add protocol, real process/HTTP, receipt/transaction and audit regressions.
  Keep native tests mandatory and preserve configuration, sessions and PQ source.

# 3.2.0-rc4 — 2026-09-10

- Adaptive bounded JSON depth scan with measured plain-span improvements and an
  escape-dense fallback; strict exponent-overflow and query-escape rejection.
- Unread-count changes update the root summary and affected rows, not the full
  stable list. Off-page changes do not reconstruct visible rows.
- Cache-only annotated conversation switcher; compact/detailed density control;
  Direct (non-group) filter; corrected client version constant.
- Added Python/HTTP, ERT and reproducible before/after JSON benchmark coverage.
  Cumulative 3.1/RC1/RC2/RC3 anchors; native/live acceptance remains a release gate.

## 3.2.0-rc3 — 2026-09-09

- Read-only Python subprocess transport with response/framing/JSON limits and
  POSIX total read deadline; string-keyed native Emacs JSON parsing when available.
- Changed-row root updates, focus-aware read acknowledgements, explicit loading
  states, automatic polling that honors pause, and Write draft shortcut.
- Viewport-only idle prefetch, shared queued media-open intent, correct originating
  buffer for media-job polls, cache-eviction retry eligibility and stale-send guard.
- Cumulative exact 3.1/RC1/RC2 compatibility anchors with two mandatory native
  validation passes; audit now rejects source mutations during each run.
- Added real HTTP/subprocess, installer/controller and native ERT regressions.
  See the RC3 audit for executed versus blocked results; no production guarantee.

## 3.2.0-rc2 — candidate, 2026-09-09

- Add authenticated v2 conditional chat/list snapshots and bounded recent-history windows.
- Move v2 preview/open downloads into two bounded worker/result slots; keep legacy routes.
- Cache summaries, serialize outside the store mutex and index client chat names.
- Render compact two-line conversation rows, 80 initially; preserve full-cache search.
- Splice changed transcript tails and sliding windows; update images without text erasure.
- Add unread navigation, context actions, guarded quick launch and read-only latency doctor.
- Add 20 ERT cases, 10 native bridge HTTP cases and 18 executable Python cases.
- Require two native changed-code audit passes, including Guile, before installation.
- Preserve configuration, sessions and pqenv; bridge restart is required to activate v2.
- Validation remains incomplete: native runtimes were unavailable. No production claim.

# Changelog

All notable changes to WhatsApp.el are documented here. This project adheres to
[Semantic Versioning](https://semver.org/).

## [3.2.0-rc1] — 2026-09-09

### Added
- Mouse-first workspace launcher and sidebar; explicit attachment preview/send stage.
- Bounded 100-message initial render with Show older, preview-spec cache and coalesced image repaint.
- Asynchronous text sends and a size-bounded Python upload worker with account-pinned recipients.
- Fit/zoom/original image controls and hardened local mpv playback with owned temporary-file cleanup.
- Explicit FFmpeg voice capture (Opus audio), Stop/Preview/Send, and optional GIF-to-MP4 copies.
- Hash-anchored candidate-audited updates, rollback journals and strict-host-key IONOS deployment.
- Isolated publication worktree, curated commit paths and four-forge hidden-token publication.
- Native ERT regressions plus Python, loopback HTTP, media-fixture, archive and Git isolation tests.
- English and Brazilian Portuguese guides, release-audit limitations and implementation prompt.

### Fixed
- Synchronous interactive sending, whole-history rendering for every image completion,
  and repeated decoding of cached previews.
- Media mouse events using an unrelated cursor position; newer draft text being deleted on send.
- Player files being removed by an arbitrary timer rather than player lifetime.
- Inconsistent attachment transport labels and token-bearing TLS key-log inheritance.

### Validation status
- See docs/AUDIT-3.2.0-rc1.md for executed tests and explicit BLOCKED/NOT RUN gates.
- No live WhatsApp sends, production deployment or forge pushes were performed during preparation.
- Bridge/PQ code and state are intentionally outside this delta. No new cryptographic claim is made.

## [3.1.0] — 2026-09-09 (upgrade candidate)

### Added
- Native dashboard actions, filtering, command palette and attachment picker.
- Original-file document delivery and wider MIME recognition with safe document fallback.
- Asynchronous refresh, bounded image prefetch/cache, and unchanged-history rendering guard.
- Regression suites for Emacs, Guile, local HTTP integration, publication and PQ state.
- Safe fish entry points for isolated patch application and four-host publication.
- A working audit command, English/pt-BR usage, deployment and audit documentation.

### Fixed
- Token-bearing bridge logging, shell interpolation in LID lookup, malformed JSON handling,
  duplicate/own-message unread counts, live history loss during sync and timestamp sorting.
- JSON boolean handling, contact-key paths, attachment routing and cache growth in Emacs.
- Optional PQ state concurrency, atomic private-file replacement, parser suffix acceptance,
  replay-store error handling, and unsafe optional Org export/capture behavior.
- Setup permissions and locked builds; systemd shell-style environment loading; Guix
  wuzapi environment loading and explicit loopback bind.

### Compatibility
- Keep your existing `.env`, wuzapi session and PQ identity. New bridge tokens must be
  URL-safe and at least 16 characters. Default upload size is 16 MiB; larger files
  require matching client/bridge limits and a compatible wuzapi deployment.
- Original images and unsupported native formats use document delivery. This release
  does not introduce transcoding, a different WhatsApp protocol engine, or a browser UI.
- See the audit for dependency updates, validation evidence and remaining limitations.

## [3.0.3] — 2026-06-17

### Added
- **Native quoted reply.** Replying to a message now threads it server-side via
  WhatsApp's `ContextInfo` (`StanzaID` + `Participant`), not just a local quote.
  `C-c C-r` sets the reply target (shown above the input; `C-c C-k` cancels), the
  next send carries the context, and inbound replies render their quoted text
  inline. Bridge `/send` accepts `reply_id`/`reply_participant`/`reply_text`.
- **Media retry for expired media.** `R` on a media line (or the action menu) asks
  the sender to re-upload media whose CDN URL has expired, via a new bridge
  `POST /mediaretry` and an optional wuzapi patch
  ([`contrib/wuzapi/`](contrib/wuzapi/)) that triggers whatsmeow's
  `SendMediaRetryReceipt` and, on the async response, decrypts it and refreshes the
  stored `directPath`. Best-effort (sender must be online and still have the media).
- **Targeted re-sync.** `POST /sync {"jid": ...}` re-imports a single chat (used
  after a media retry); `C-c w S` / `M-x whatsapp-sync` triggers it.

## [3.0.2] — 2026-06-16

### Fixed
- **Media downloads (images, stickers, video, audio, documents).** The bridge now
  sends `DirectPath` alongside the URL/keys and routes each kind to the correct
  wuzapi endpoint — crucially `sticker → /chat/downloadsticker` (it previously hit
  `/chat/downloadimage` and failed). History rows now carry the same download
  fields a live webhook would, so any in-window media is downloadable. Verified
  end to end against fresh media. (Media older than WhatsApp's CDN retention still
  cannot be re-fetched — shown as an honest, retryable "expired" label.)

### Added
- **Telega-style message actions** in the client: a `C-c C-m` action menu plus
  direct keys to react (emoji), quote-reply, forward to another chat, copy text,
  save media to a file, delete (for everyone, when yours) and mark read. Backed by
  new bridge endpoints `POST /react`, `/delete`, `/markread`.
- **Inline media polish**: WebP stickers and images render inline scaled to
  `whatsapp-image-max-width` / `whatsapp-sticker-max-width`; media regions are
  click/`RET`-to-open and `s`-to-save.

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
