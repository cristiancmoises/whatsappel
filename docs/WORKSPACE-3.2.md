# WhatsAppel 3.2.0-rc1: use, install and deploy

## Scope and prerequisites

This is an Emacs desktop workspace, not an HTTP/browser app. The Guile bridge,
wuzapi and optional pqenv Rust code are retained. A Python worker moves upload
I/O and explicit GIF conversion orchestration out of the Emacs thread. Existing
Org integrations retain their synchronous low-level helper; not every legacy
command (for example Connect, QR, Sync, Save or Forward) becomes asynchronous.

Use graphical Emacs 28.1+, Python 3.10+, fish, Git and coreutils. Media features
need mpv and FFmpeg with PulseAudio input, libopus and libx264. PipeWire can provide
the PulseAudio input server. The desktop needs an actual microphone permission
and input device; a passing synthetic Opus test does not establish those.

The default per-file limit is 16 MiB. Inline image canvases are restricted to
16 million source pixels and 16,384 pixels on either axis. The client initially
renders 100 retained messages. Show older expands only already-fetched history;
it is not unlimited server-side history pagination. The preview-spec cache holds
at most eight entries within its declared-source-pixel budget. These limits are
not a claim that the entire Emacs process has a fixed total RSS.

## Install from the extracted update package

Run in fish, after placing/extracting the archive in Downloads:

```fish
cd ~/Downloads/whatsappel-update-3.2.0-rc1
python3 scripts/update-package.py ~/whatsappel
and fish scripts/install-local.fish ~/whatsappel
```

The first command only checks compatibility and checksums. The second stages the
candidate, runs native changed-code gates, creates a private rollback journal,
replaces only hash-matched managed files, removes stale matching-client bytecode,
and installs a user-level menu/CLI launcher. Missing tools or failing tests stop
before installed source changes. No `BASELINE_COMMIT` placeholder is required.
The installer also supports a non-Git source installation, provided it contains
the complete 3.1.0 source/test inputs. It never turns an arbitrary directory into
a Git repository or overwrites unrecognized changes.

A full audit, independent of the install gate, can be requested on a complete
updated checkout with:

```fish
python3 scripts/audit-workspace.py . --scope full
```

Audit logs are placed outside the checkout. Full-scope Guile/Rust checks and live
acceptance are distinct from the changed-code install gate. No bypass flag turns
missing runtimes into successful validation.

## Start and use

Restart the WhatsAppel Emacs instance after updating. Click **WhatsAppel** in the
application menu, or run `~/.local/bin/whatsappel`. The launcher opens a dedicated
Emacs process, loads the updated source and retains normal Emacs initialization.
It reads only literal, whitelisted assignments from a user-owned `.env`; it does
not execute/source that file. Existing Emacs token settings still work. Bridge
configuration and initial WhatsApp pairing are prerequisites, not silently created
accounts. The dashboard shows the release-candidate version.

Select a conversation in the left sidebar. Filter All / Unread / Groups or use
Search. The compose area has Send, Image, Video, GIF, Record voice, File and the
existing Encrypted send control. Enter sends a draft; C-j inserts a newline. Send
requests run asynchronously, retain newer draft edits and reject duplicate sends
while pending. An unconfirmed send keeps the draft with a warning: inspect the
conversation before retrying, because a timeout does not prove non-delivery.

Attachments first open a recipient-pinned stage. Use Preview, Caption and Send;
Cancel discards only owned temporary output. File sends preserve original bytes.
Unsupported inline formats fall back to documents. Selecting a file does not send
it. A changed bridge account invalidates an existing attachment stage.

For voice, click Record voice, then Stop recording, Preview and Send. Recording is
bounded to 180 seconds by default (configurable up to ten minutes), mono 48 kHz
Opus audio. Microphone use is never automatic. The existing bridge sends this as
audio; it does not add a native WhatsApp PTT flag. A voice-note badge is therefore
not guaranteed. Normal attachment sends are not pqenv-enveloped attachments.

A raw GIF remains an original document. **Prepare MP4 copy** explicitly creates a
separate, silent, at-most-30-second copy fitted into 720×720, with even dimensions
and a 16 MiB output ceiling. Its original is unchanged. The existing `/send/gif`
bridge endpoint is an MP4 video alias, so native WhatsApp GIF looping is not
promised. Local GIF previews can loop in mpv until the player is closed.

Click received media to open the exact clicked message. Static PNG/JPEG/WebP
previews have Fit, −, + and Save original. Unsupported/oversized canvases remain
available through original-file saving instead of native image decoding. Video
and audio use mpv controls. A private local snapshot is removed when that owned
player exits, not after an arbitrary ten-minute timer. This is not a general
sandbox for all vulnerabilities in third-party decoders.

## IONOS: copy and guarded client-source deployment

```fish
cd ~/Downloads/whatsappel-update-3.2.0-rc1
fish scripts/deploy-ionos.fish
```

The helper uses **root@securityops.co, port 5119**, requires an already-verified
SSH host key, builds/transfers a checksummed archive, rejects unsafe tar members,
and looks for exactly one existing `/root/whatsappel` or `/opt/whatsappel` source
directory. When needed, provide its actual absolute path:

```fish
fish scripts/deploy-ionos.fish --target /root/whatsappel
```

That path is an example candidate, not an assertion about the live VPS. Ambiguous
or missing installations stop. `--stage-only` uploads and checks without replacing
installed files. Never disable host-key checking to get past a host-key warning;
verify the fingerprint through your trusted server-management channel.

Remote native gate prerequisites on Debian include Python 3, Git, fish, FFmpeg,
mpv and Emacs (the non-graphical Emacs package can run batch tests). The script does
not install system packages behind your back. A blocked gate leaves the running
installation alone and prints the retained audit/package location.

**This patch does not change the bridge or wuzapi.** Consequently deployment copies
client source but does not restart those services, rebuild Docker, publish a web
port, modify NPM, relink WhatsApp, replace PQ keys or migrate any message database.
The visible interface and microphone belong on the workstation. For a VPS bridge
kept on loopback, a foreground SSH tunnel can expose it to the workstation:

```fish
ssh -N -T -p 5119 -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -L 127.0.0.1:17337:127.0.0.1:7337 root@securityops.co
```

This assumes the existing remote bridge listens on port 7337; use its actual
configuration otherwise. Set the Emacs bridge origin to `http://127.0.0.1:17337`
and use the existing remote bridge token through your protected configuration.
Do not put tokens into URLs or paste them into command history. Keep an existing
local bridge on 7337 unchanged; the separate local port avoids taking it over.

## Commit and publish all four remotes

```fish
cd ~/Downloads/whatsappel-update-3.2.0-rc1
fish scripts/commit-and-push.fish ~/whatsappel --branch main
```

A separate `~/whatsappel-publish-3.2.0-rc1` worktree starts from the existing Git
checkout's committed HEAD. Uncommitted work in the original checkout is retained,
not silently included in this release. For a non-Git installation, the helper
creates a separate public Codeberg clone. It requires your real configured Git
identity, applies the content-anchored delta after its native gate, and stages only
the manifest's paths. It never runs `git add -A` on your active working directory.

Publication is then attempted independently to `git.securityops.co/cristiancmoises`,
`git.securityops.com.br/cristiancmoises`, `github.com/cristiancmoises` and
`codeberg.org/berkeley`, always for the **whatsappel** repository. The helper asks
for each token with hidden terminal input. Repository-specific credentials are
served from memory through a private local socket; tokens are not put in Git
URLs, process arguments, persistent credential files or logs. TLS verification
and redirect refusal remain enabled. API 5xx errors do not establish bad tokens.

Existing missing/inaccessible repositories cause a per-host failure by default.
Explicitly authorize creation of missing public repositories with:

```fish
fish scripts/commit-and-push.fish ~/whatsappel --branch main --create-missing --visibility public
```

Use private visibility instead only when that is intended; existing visibility
is never silently changed. Rerunning continues using the preserved publication
checkout. Ahead/divergent remotes require reconciliation, not a force push.
`--commit-only` stops after the local commit; `--remote github` limits publication
to a named destination. Tags and hosted releases are not automatically created.

## Rollback and remaining acceptance

Each successful installation prints its exact backup directory and rollback
command. Run the printed `python3 .../rollback.py --rollback ...` command rather
than guessing a timestamp. It verifies backup hashes and refuses to overwrite
files changed after installation. It restores old source and saved bytecode but
does not need to touch the unchanged bridge, sessions or PQ state. Restart the
Emacs instance afterward. Backup deletion is never automatic.

The rc1 audit explicitly leaves native and live checks pending where runtimes or
accounts were unavailable. Before routine production use, validate desktop
launching, click targeting, image zoom, mpv windows, microphone Stop/Preview/Send,
actual delivery of each chosen media format and legacy Org operations against
your existing wuzapi version. No fake screenshot or certification is substituted
for those checks.
