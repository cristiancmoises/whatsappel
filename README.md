<p align="center">
  <img src="assets/logo.png" alt="whatsapp.el" width="260">
</p>

<h1 align="center">whatsapp.el</h1>

<p align="center">
  <b>A full WhatsApp client for Emacs.</b><br>
  Chat from your editor — fully local, no cloud, no middlemen.
</p>

<p align="center">
  <img alt="Emacs 28+" src="https://img.shields.io/badge/Emacs-28%2B-7F5AB6?logo=gnuemacs&logoColor=white">
  <img alt="Node 18+" src="https://img.shields.io/badge/Node-18%2B-339933?logo=nodedotjs&logoColor=white">
  <img alt="License GPL-3.0" src="https://img.shields.io/badge/License-GPL--3.0-blue">
  <img alt="Version 2.7.2" src="https://img.shields.io/badge/version-2.7.2-25D366">
</p>

---

`whatsapp.el` turns Emacs into a real WhatsApp client. An Emacs Lisp front-end
talks to a small local **Node.js bridge** (powered by
[Baileys](https://github.com/WhiskeySockets/Baileys)) that speaks the WhatsApp
Web protocol. Everything runs on your machine — your session, your messages,
your media never touch a third-party server.

> Telega for Telegram, ement for Matrix… this is the one for WhatsApp.

## 📦 Repositories

**Official** (development happens here):

- Forgejo (primary): <https://git.securityops.co/cristiancmoises/whatsappel>
- Codeberg: <https://codeberg.org/berkeley/whatsappel>

**Mirror** (read-only):

- GitHub: <https://github.com/cristiancmoises/whatsappel>

Please open issues and pull requests on the **Forgejo** or **Codeberg** repositories.

## ✨ Features

**Messaging**
- Click a chat and just **type** — `RET` sends, `C-j` for a newline (telega-style input).
- Send & receive text, **reply with quote**, **react** with emoji, **edit**, **delete** (for me / everyone), **forward**, **star**, mark read.
- Real-time delivery & read receipts (✓ / ✓✓), typing indicators, online presence.

**Media**
- **Inline images**; **looping GIFs** and animated stickers; click-to-play **video** and **voice notes** (via `mpv`).
- **Record & send voice messages** (`C-c v`), attach any file, send location, polls, and contact cards.

**Chats & contacts**
- Chat list with avatars, unread badges, pin / mute / archive, and live ordering.
- **Names that actually resolve** — full support for WhatsApp's new `@lid` addressing: real names, phone numbers, and group subjects (no more walls of meaningless numbers).
- Global & per-chat search, starred messages, groups (create / manage / invite).

**Under the hood**
- Persistent session — scan the QR **once**.
- Message history persists across restarts; on-demand paging for older messages.
- Fully local; optional bearer-token auth and rate limiting on the bridge.
- Works on GNU/Linux, macOS, and Windows.

## 🏗️ Architecture

```
   Emacs                         Local bridge (Node)              WhatsApp
┌────────────┐   REST :3000   ┌────────────────────┐   Baileys   ┌──────────┐
│ whatsapp.el│◀──────────────▶│     server.js      │◀───────────▶│   Web    │
│  (client)  │   WS   :3001   │ (@whiskeysockets/   │  protocol   │ servers  │
└────────────┘◀──────────────▶│      baileys)      │             └──────────┘
                              └────────────────────┘
```

- **`lisp/whatsapp.el`** — the Emacs client (UI, buffers, keybindings).
- **`server.js`** — the bridge: REST API on `:3000`, WebSocket push on `:3001`, session in `auth_info/`, state in `store.json`.

## ⚙️ Requirements

- **Emacs ≥ 28.1** with the [`websocket`](https://melpa.org/#/websocket) package
- **Node.js ≥ 18** and **npm**
- A phone with WhatsApp (to link the device once)
- Optional: `mpv` (audio/video playback), `sox`/`ffmpeg`/`arecord` (voice recording)

## 🚀 Installation

### 1. Get the code

```sh
git clone https://git.securityops.co/cristiancmoises/whatsappel.git
cd whatsappel
```

### 2. Start the bridge

```sh
npm install
node server.js
```

The first time, a QR code is printed. On your phone open
**WhatsApp → Linked Devices → Link a device** and scan it. The session is saved
to `auth_info/`, so you only do this once.

Prefer a background service? Use the provided unit:

```sh
make install            # or copy whatsappel.service to ~/.config/systemd/user/
systemctl --user enable --now whatsappel
```

### 3. Load the Emacs client

Put `lisp/whatsapp.el` on your `load-path` and `require` it. The included
[`init.el`](init.el) is a ready-to-copy example. Minimal version:

```elisp
(add-to-list 'load-path "/path/to/whatsappel/lisp")
(require 'whatsapp)
(global-set-key (kbd "C-c W") #'whatsapp-connect)
```

### 4. Connect

`M-x whatsapp-connect` (or `C-c W`). The chat list opens — **click a chat and
start typing.**

## 💬 Daily use

1. `C-c W` opens the chat list.
2. **Click** (or `RET`) a chat to open it.
3. **Type your message** and press `RET` to send (`C-j` for a newline).
4. Press `c` in the chat list to start a **new conversation** with any contact or number.
5. Inside a chat, everything else is under the **`C-c` prefix** — or press `C-c h` for the action menu.

## ⌨️ Keybindings

**Chat list**

| Key | Action |
|-----|--------|
| `RET` / `mouse-1` | Open chat |
| `c` | New message |
| `C` | Contacts browser |
| `g` | Refresh · `s` filter · `S` search messages |
| `G` | Create group |
| `A` / `P` / `M` | Archive / Pin / Mute |
| `1` `2` `3` `0` | Filter unread / groups / direct / clear |
| `*` | Starred · `h` actions · `q` bury |

**Inside a chat** — *just type to compose*

| Key | Action |
|-----|--------|
| `RET` | Send |
| `C-j` / `S-RET` | Newline |
| `C-c r` / `C-c e` / `C-c E` | Reply / React / Edit |
| `C-c d` / `C-c f` / `C-c w` | Delete / Forward / Copy text |
| `C-c a` / `C-c v` | Attach file / Voice note (toggle record) |
| `C-c m` / `C-c M` | Play media / Download |
| `C-c l` · `C-c C-p` · `C-c C-v` | Location · Poll · Contact card |
| `M-p` / `M-n` | Previous / next message |
| `C-c g` / `C-c <` | Scroll to bottom / Load older |
| `C-c h` | **Action menu** (everything) |

`mouse-1` on an image, video, GIF, or voice message plays/opens it. Right-click any message for a context menu. Full list: `M-x whatsapp-help`.

## 🔧 Configuration

```elisp
(setq whatsapp-server-host "localhost"
      whatsapp-server-port 3000
      whatsapp-ws-port     3001
      ;; whatsapp-api-token "shared-secret"   ; only if the bridge sets WAEL_API_TOKEN
      whatsapp-inline-images       t          ; show photos inline (GUI Emacs)
      whatsapp-animate-gifs        t          ; loop GIFs / animated stickers
      whatsapp-show-profile-pics   t          ; avatars in the chat list
      whatsapp-auto-read           t
      whatsapp-typing-indicator    t
      whatsapp-audio-player        "mpv"
      whatsapp-video-player        "mpv"
      whatsapp-voice-record-command "sox")    ; or "ffmpeg" / "arecord"
```

The bridge is configured via environment variables: `WAEL_PORT`, `WAEL_WS_PORT`,
`WAEL_AUTH_DIR`, `WAEL_MEDIA_DIR`, `WAEL_STORE_FILE`, `WAEL_API_TOKEN`,
`WAEL_RATE_LIMIT`, `WAEL_LOG_LEVEL`. See [`docs/BRIDGE.md`](docs/BRIDGE.md) and
[`openapi.yaml`](openapi.yaml) for the full REST/WebSocket reference.

## 🔒 Privacy & security

Everything is local. Your linked-device session lives in `auth_info/` and your
chats in `store.json` — **never commit or share these** (they're already in
`.gitignore`). The bridge listens only on `localhost`; enable `WAEL_API_TOKEN`
if you expose it.

## ✍️ A note from the author

Here in Brazil, WhatsApp is practically a necessity — so much so that I once
bought a brand-new smartphone *just* to install it and keep in touch with a few
friends, family, and work.

This project grew out of a simple wish: to live inside Emacs for everything, all
day long. Now you can (almost) put your smartphone down too.

Feel free to use this tool. If you like it, please share it with your friends.
Have a nice day.

Remember… **in code we trust.**

— *Cristian Cezar Moisés*

## 🤝 Contributing

Issues and pull requests are welcome on the official
[Forgejo](https://git.securityops.co/cristiancmoises/whatsappel) and
[Codeberg](https://codeberg.org/berkeley/whatsappel) repos. See
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## 📜 License

Released under the **GNU General Public License v3.0** — see [`LICENSE`](LICENSE).

<p align="center"><i>Enjoy messaging from the comfort of Emacs ⚡</i></p>
