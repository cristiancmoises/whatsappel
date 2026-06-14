# Contributing to WhatsApp.el

## Quick Start

```bash
git clone https://codeberg.org/berkeley/whatsappel.git
cd whatsappel
npm install
make test
```

## Development Workflow

1. Start the server: `node server.js`
2. Load `whatsapp.el` in Emacs: `M-x load-file RET whatsapp.el`
3. Connect: `M-x whatsapp-connect`
4. Make changes, re-evaluate with `C-x C-e` or `M-x eval-buffer`

## Code Style

### Elisp
- `lexical-binding: t` always
- Prefix all symbols with `whatsapp-` (public) or `whatsapp--` (internal)
- All faces use `inherit` — never hardcode colors
- Byte-compile clean: `make compile`
- Follow Emacs Lisp coding conventions (Info node `(elisp) Tips`)

### JavaScript
- `'use strict'`
- Async/await, no callback pyramids
- All endpoints return `{ ok: true, data: ... }` or `{ ok: false, error: "..." }`
- Syntax clean: `node -c server.js`

## Testing

```bash
make test           # Syntax checks
make test-server    # Endpoint tests (server must be running)
```

## Adding a New Feature

1. **Server endpoint** — add to `server.js` following the existing pattern
2. **Elisp command** — add interactive function prefixed `whatsapp-chat-`
3. **Keybinding** — add to the appropriate mode map
4. **Help text** — update `whatsapp-help`
5. **Actions menu** — add to `whatsapp-chat-actions` if appropriate
6. **README** — document the feature, keybinding, and any new config vars
7. **CHANGELOG** — add entry under `[Unreleased]`

## Bug Reports

Include:
- Emacs version (`M-x emacs-version`)
- Node.js version (`node --version`)
- Server log output (run with `WAEL_LOG_LEVEL=debug node server.js`)
- Steps to reproduce
- The `*Messages*` buffer output

## License

By contributing, you agree that your contributions will be licensed under GPL-3.0.
