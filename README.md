# WhatsAppel

**A native WhatsApp client for Emacs, built around Guile, wuzapi/whatsmeow, Python workers and optional post-quantum tooling.**

Current release candidate: **3.2.0-rc17**.

WhatsAppel is designed for people who want messaging to live inside Emacs without turning Emacs into a browser wrapper. The client focuses on responsive chat navigation, explicit delivery states, media workflows, privacy-aware profile data, reproducible GNU Guix deployment and guarded updates.

> **Release status:** RC17 is a release candidate. Provider acceptance is not the same as recipient delivery, profile data remains subject to WhatsApp privacy/backend support, and Pale playback is still experimental/unverified. The project intentionally keeps these states explicit instead of presenting unverified behavior as success.

## Screenshots

The screenshots below are from the native Emacs interface. The two conversation screenshots had only the Emacs modeline/footer cropped to remove a local account identifier; the other screenshots are included unchanged.

### Contact list and workspace

![WhatsAppel contact list](docs/screenshots/whatsappel-root.png)

### Accepted send and delivery controls

![WhatsAppel accepted send](docs/screenshots/whatsappel-accepted.png)

### Workspace settings

![WhatsAppel settings](docs/screenshots/whatsappel-settings.png)

### Images and chat media

![WhatsAppel image view](docs/screenshots/whatsappel-image-view.png)

### Media inside a conversation

![WhatsAppel media conversation](docs/screenshots/whatsappel-media.png)

More screenshot notes: [docs/SCREENSHOTS.md](docs/SCREENSHOTS.md).

## Highlights

- **Native Emacs UI** with contact list, chat buffers, mouse actions and keyboard-first workflows.
- **Responsive conversation opening** with deferred history/media work and bounded previews.
- **Delivery-aware sending** that distinguishes pending, provider acceptance, delivered, read, rejected and unconfirmed states.
- **Recipient identity preservation** for phone JIDs, LIDs and groups without guessing unsupported mappings.
- **Images and media** with native image handling, bounded GIF support, voice recording, attachments and explicit playback controls.
- **Profile photos and presence plumbing** with bounded caches, privacy-aware fallbacks and opt-in presence observation.
- **Delivery diagnostics** for bridge/provider state, callback registration and subscriptions.
- **Optional encrypted/PQ workflows** via the retained `pqenv` component.
- **GNU Guix-friendly deployment** with Fish entry points and no required `sudo`/`guix pull` for normal app updates.
- **Guarded updates and publication** using exact hashes, private backups, rollback checks and non-force pushes.

## Architecture

```text
Emacs Lisp client
       │
       ├── Python workers ── media/profile/read/send helpers
       │
       └── Guile bridge ──── authenticated loopback HTTP
                              │
                              └── wuzapi / whatsmeow
                                      │
                                      └── WhatsApp
```

Optional components include FFmpeg, mpv, Pale integration work, Org integration and the Rust `pqenv` utility.

## GNU Guix installation / update

Use the release/update bundle rather than copying files manually over an installation. From an extracted release bundle:

```fish
fish scripts/update-and-activate.fish "$HOME/whatsappel" --restart-local
```

The guarded workflow runs its required audits before replacing managed files, preserves `.env`, sessions, init files and independently newer PQ data, and refuses unknown local modifications.

After a successful client update, fully restart Emacs (including an Emacs daemon if used) so the new Lisp definitions are actually loaded.

## Everyday use

Common actions are available directly in the WhatsAppel buffers:

- search/switch/new/refresh conversations;
- send text and files;
- preview/send images, video and GIF media;
- record and preview voice audio before sending;
- retry failed image work;
- inspect connection and delivery state;
- clear local send notes explicitly;
- open profile/settings/diagnostic views.

The application avoids automatic retries for uncertain sends to reduce duplicate-message risk.

## Media

Static images are displayed inside Emacs when supported. GIF handling is bounded. Audio uses the explicit local player path. Video playback can be selected from WhatsAppel settings; **mpv is the established playback path while Pale integration remains experimental/unverified**.

## Presence and profile information

Presence is evidence-based. WhatsAppel does not infer remote “online”, “offline” or “idle” merely from silence or message age. Profile photos, last-seen and activity indicators depend on backend support, subscriptions and the remote account's privacy settings.

## Security model

WhatsAppel aims to reduce accidental credential and state exposure:

- bridge authentication and loopback-first operation;
- tokens are not embedded in repository URLs by the publishing workflow;
- bounded worker responses and deadlines;
- redirect/destination checks for controlled media/profile retrieval;
- explicit confirmation before potentially disruptive callback repairs;
- no automatic replay of uncertain sends;
- content-anchored updates and rollback refusal after newer edits.

These controls are not an independent security certification, a full decoder sandbox or a claim that every external provider behavior is trustworthy.

## Development and validation

Important validation areas include:

```text
Emacs byte compilation + ERT
Guile unit/integration tests
Python worker regressions
Fish syntax/workflow checks
FFmpeg/mpv checks
Rust tests / formatting / Clippy
source-integrity verification
```

See the release audit documentation for the exact results of a specific candidate. A passed fixture does not substitute for live recipient delivery or graphical acceptance.

## Documentation

- [RC17 send-failure repair](docs/SEND-FAILURE-3.2.0-rc17.md)
- [RC17 audit](docs/AUDIT-3.2.0-rc17.md)
- [Screenshots](docs/SCREENSHOTS.md)
- [Português](README.pt-BR.md)

## Project

- Codeberg: `codeberg.org/berkeley/whatsappel`
- GitHub: `github.com/cristiancmoises/whatsappel`
- Security Ops forges: `git.securityops.co/cristiancmoises/whatsappel` and `git.securityops.com.br/cristiancmoises/whatsappel`

## License

AGPL-3.0-only. See [LICENSE](LICENSE).
