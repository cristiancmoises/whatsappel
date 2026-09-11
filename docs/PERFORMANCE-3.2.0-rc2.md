# RC2: chat loading, native interaction and validation

**Candidate only. Native Emacs/Guile execution remains blocked in the preparation
environment. Do not treat the Python or structural results as GUI validation.**

## What the patch changes

The client asks for the latest 60 retained messages rather than receiving every
retained record at each poll. Load older expands the requested window in steps
of 60, up to 10,000; this does not recover messages missing from the bridge's
retained/imported store. With the default 500-record bridge cap, 60 rather than
500 records means 88% fewer records in an initial full window, **not an 88% speed
claim**. Actual bytes depend on text and media metadata.

Read API v2 returns a process-scoped revision. Unchanged polls omit the record
array. Revisions reset on bridge restart. Chat summaries are cached until store,
name or unread mutations invalidate the cache, and JSON serialization occurs
outside the store mutex. Root previews are capped at 240 characters.

The conversation list initially renders 80 compact, two-line rows. Search and
All/Unread/Groups filtering inspect the entire cached list, not just that first
page. More expands the view. The sidebar is 38 columns when the frame is wide
enough. New/opened chats display cached content before requesting an update.
The selected row, unread count and native buttons keep mouse use possible.

Message actions are accessible by right-click, C-c . or the existing menu
binding. C-c C-f still forwards; C-c / searches loaded messages. M-g u opens the
next unread cached chat. Set whatsapp-show-message-actions to t to restore the
per-message Actions button. Existing explicit attachment, voice, image viewer,
mpv playback, GIF conversion, recipient preview and encryption controls remain.
This is an Emacs interface, not a browser application or a complete telega clone.

New incoming text updates the changed tail. When a bounded history window moves
forward, overlapping records can remain in place and only the dropped head/new
tail changes. The draft text and marker are not recreated on that fast path.
Layout changes use the older full renderer as a fallback. Image completions now
change the placeholder's display property rather than erase the transcript.
Name lookup uses a snapshot index rather than a list scan on every header redraw.

## Media isolation and its boundaries

On a v2 bridge, automatic previews and normal click-to-open media submit once to
POST /download?async=1 and poll the authenticated GET /media-job endpoint. There
are at most two pending/running/completed results. Completed uncollected results
expire after 60 seconds. A collected result is removed. All original CDN URL,
metadata, size and token validation remains in handle-download. The same token
is required for submission and result retrieval; this remains a single-account
bridge, not a new multi-tenant authorization system.

This prevents those download workers from synchronously performing upstream
HTTP in the main chat-read handler. It does not make every endpoint concurrent:
legacy downloads, explicit history Sync, Connect, forward/save/react/delete and
other old synchronous operations can still block their caller or the bridge.
A hung upstream can occupy a worker until the upstream operation ends; the
thread pool is bounded but this patch does not forcibly cancel Guile HTTP calls.
The Emacs side times out and reports failure. Busy workers are not retried in an
automatic POST loop. Expired CDN media still requires a real sender-side retry.

No sessions, pqenv files, wuzapi binary, network ports, NPM configuration or
cryptographic formats are changed. Audio remains the existing Opus audio route;
this does not add WhatsApp-native PTT or GIF-loop flags.

## Install/check from fish

Extract the rc2 bundle beside the existing installation. Its payload is a delta
against the exact rc1 managed files, not a whole-repository replacement. The
GitHub client and bridge blobs matched the retained rc1 source; current Codeberg
HEAD and all other files were not independently proven identical. Divergent
managed files are refused. Independently newer pqenv code is not overwritten.

```fish
set -l bundle "$HOME/Downloads/whatsappel-update-3.2.0-rc2"
python3 "$bundle/scripts/update-package.py" "$HOME/whatsappel" --bundle "$bundle"
```

Run both full native passes against a temporary candidate, without installation:

```fish
python3 "$bundle/scripts/update-package.py" "$HOME/whatsappel" \
    --bundle "$bundle" --audit-only --full-audit
```

Only after that command succeeds, install through the guarded entrypoint:

```fish
fish "$bundle/scripts/install-local.fish" "$HOME/whatsappel"
```

Installation itself again runs two changed-code audit passes, including Guile
because rc2 changes bridge code. Missing tools or a failed pass stops before
installed source writes. The existing fish entrypoints call bundled Python
helpers; keep the whole bundle together. Guile 3 + guile-json, Emacs >=28.1,
Python >=3.10, fish, mpv and FFmpeg are needed for changed-scope gates. Full scope
also needs the existing project's Rust/Cargo dependencies.

Restart Emacs to load the new client. **Restart the existing bridge launcher or
service to enable v2.** The installer does not guess your active systemd/Shepherd/
Docker deployment or restart wuzapi. A source copy alone is not a running bridge
upgrade. The normal launch keeps your init:

```fish
"$HOME/.local/bin/whatsappel"
```

An optional isolated launch avoids init/plugin initialization overhead:

```fish
"$HOME/.local/bin/whatsappel" --quick
```

Quick mode uses Emacs -Q and requires WHATSAPPEL_TOKEN in protected .env or the
environment. It refuses to silently start without init-only credentials. Its
speed is not benchmarked in this environment and it does not retain init themes.

## Read-only diagnosis, usable before installation

Run on the machine that can reach your existing bridge. Specify the actual
origin when it differs from loopback. No message text, names, token, URL, JID or
raw response is included in the report. The report file is new-only and mode0600.

```fish
python3 "$bundle/scripts/doctor-performance.py" \
    --config "$HOME/whatsappel/.env" \
    --output "$HOME/Downloads/whatsappel-latency-"(date -u +%Y%m%dT%H%M%SZ)".json"
```

The token can instead be entered at a hidden prompt; there is no token argument.
read_api=1 identifies an old bridge: the doctor deliberately does not call /chat,
because the legacy route marks messages read. read_api=2 enables read=0 window
and conditional probes. HTTP time includes network, queueing and bridge work;
it is not an Emacs rendering benchmark or a WhatsApp delivery test. Do not
publish other operational logs that may contain your normal account data.

`make benchmark-client` records synthetic batch-Emacs layout timings once a
native Emacs is available. It does not measure images, actual GUI rendering,
microphone access, network latency or wuzapi synchronization.

## VPS and publication helpers

The package retains scripts/deploy-ionos.fish for root@securityops.co:5119 with
mandatory SSH host verification. Use --stage-only to upload/check without source
installation. A source installation does not restart the active bridge; verify
read_api=2 after restarting its existing launcher. Do not replace services or
containers based only on a guessed name.

scripts/commit-and-push.fish creates a separate rc2 worktree and applies the
native-gated delta before committing. It preserves unrelated local work and
uses hidden token prompts and non-force pushes to the four previously configured
forges. There is no automatic new release/tag or remote CI workflow in this
patch. No deployment or publication was executed while preparing this bundle.
One empty audit branch was created on GitHub before workflow creation was
explicitly declined; the declined workflow was not created or retried.

## Manual release acceptance

After native gates pass, use a test conversation with consenting recipients.
Check initial list load and cached switching, 80+ conversations/search, incoming
messages while typing, reply cancellation, older-window expansion, unread
counts, GUI image fit/save, mpv video/audio, attachment cancellation, duplicate
clicks, actual recipient receipt, a physical microphone and offline/reconnect.
Compare doctor and native benchmark outputs on the same system, separately.
Keep the printed rollback backup until these checks pass. Rolling source back
also requires restarting the client and bridge to activate the restored version.
