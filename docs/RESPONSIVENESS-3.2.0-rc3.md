# WhatsAppel 3.2.0-rc3 — loading, interaction and safe update

## Status and architecture

This is a native Emacs release candidate, not a browser app. RC3 continues the
retained RC2 snapshot; current Codeberg HEAD is not established. The cumulative
bundle recognizes exact 3.1, RC1 and RC2 file contents and refuses other edits.
It does not replace unchanged pqenv, wuzapi, credentials or account/session data.
The latest executed results and limitations are in AUDIT-3.2.0-rc3.md.

## What changes during use

Opening WhatsAppel or a conversation starts one polling timer unless you explicitly
paused polling. Cached content is immediately usable; the header distinguishes
first loading, refreshing, cached snapshot age and failed refresh. A failed first
read is not displayed as an empty conversation. On the v2 bridge, background chat
reads use read=0. Automatic read acknowledgement requires the selected window in
a visible frame whose focus is definitely true. Unknown terminal focus does not
acknowledge automatically; use the existing Mark read action. An old bridge may
ignore read=0: update/restart the bridge before relying on this behavior.

The default GET transport runs one isolated Python child per snapshot or media
result request. Network work and response validation run outside the interactive
Emacs path. Native JSON parsing is used when available, with string keys and the
same false/null conventions as the legacy parser. Message sends retain their
existing transport and uncertainty/no-automatic-resend semantics. Independent
Python startup costs remain: this is not a measured reduction in WAN latency.

A child handles exactly one allowlisted GET. Snapshot responses are capped at
4 MiB; media-job results at 24 MiB. JSON depth is capped at 96. Oversized snapshots
leave the previous cache intact; decrease the loaded history window rather than
turning off guards. The default read timeout follows whatsapp-request-timeout
(30 seconds); POSIX setitimer bounds the complete network read, and Emacs also
owns a timeout at that configured value plus one second. HTTP redirects,
compressed responses, ambiguous Content-Length/Transfer-Encoding framing,
malformed/duplicate-key JSON and unexpected shapes are refused. HTTPS verifies
certificates; environment proxies are not used. This is not a decoder sandbox,
whole-process memory guarantee, or proof of TLS behavior on every local build.

Same-order, same-layout conversation updates replace only changed visible rows;
reordering, filters, page expansion or changed aggregate unread counts may still
use a bounded full redraw. Initial root rendering stays at 80 conversations and
initial history at 60 retained messages. The server remains responsible for its
retention limits: Load older is not unlimited account-history retrieval.

Image prefetch follows actual visible window ranges rather than the latest N
messages regardless of scroll position. It is scheduled after 150 ms of idle time.
Hidden queued automatic previews are dropped; an already running preview can
finish into the bounded cache. Clicking queued/active media reuses that download
and opens when it completes while the same conversation is still selected. Moving
to another chat suppresses automatic opening; the completed cache remains usable.
Click again there to open it deliberately. C-c C-b or Write returns to the draft.
Closing a chat stops only its owned read children, not other chats or services.

Image zoom, Save original, mpv playback, explicit attachment staging and voice
recording remain from RC1. Voice/GIF transport flags are unchanged: no new native
PTT badge, GIF-loop promise or pqenv attachment encryption is implied.

## Extract and verify (fish)

Download the archive and its checksum to Downloads with their original names:

```fish
cd "$HOME/Downloads"
and sha256sum -c whatsappel-update-3.2.0-rc3.tar.gz.sha256
and tar -xzf whatsappel-update-3.2.0-rc3.tar.gz
and cd whatsappel-update-3.2.0-rc3
and python3 scripts/update-package.py "$HOME/whatsappel"
```

The last command checks only; it makes no installed-source changes. The folder
must contain a complete supported source installation. It need not be a Git
repository. Independently newer unmodified PQ inputs are copied from that actual
installation into its isolated audit candidate, not replaced by bundled PQ code.
Checksums are integrity checks relative to the delivered manifest, not signatures.

## Double native audit and local install

```fish
python3 "$HOME/Downloads/whatsappel-update-3.2.0-rc3/scripts/update-package.py" \
    "$HOME/whatsappel" --audit-only --full-audit
```

This stages the candidate separately and runs the full controller twice, without
installing. It needs Emacs 28.1+, Python 3.10+, Guile/guile-json, fish, FFmpeg, mpv,
and Rust/Cargo with the retained project's dependencies for full scope. Dependencies
are not silently installed. Offline Cargo failure is failure, not a pass.

After both native passes succeed:

```fish
fish "$HOME/Downloads/whatsappel-update-3.2.0-rc3/scripts/install-local.fish" \
    "$HOME/whatsappel"
```

Installation repeats both changed-code gates, including Guile for cumulative
bridge compatibility. Missing or failing gates stop before source writes. There
is no bypass switch. Successful installation prints a private rollback directory
and exact restoration command; keep it until real acceptance is complete.

Restart the Emacs client. For installations predating RC2, also restart the actual
existing bridge process/service: cumulative RC3 includes the RC2 bridge. No service
name is guessed, no NPM/Docker change is made, no session is relinked. From RC2,
this delta does not alter the bridge code. Updating only VPS source cannot change
the Emacs UI on your laptop. Desktop launcher: ~/.local/bin/whatsappel. Its explicit
--quick mode uses Emacs -Q only when credentials are available outside Emacs init.

## Read-only measurements

```fish
python3 "$HOME/Downloads/whatsappel-update-3.2.0-rc3/scripts/doctor-performance.py" \
    --config "$HOME/whatsappel/.env" \
    --output "$HOME/Downloads/whatsappel-latency-"(date -u +%Y%m%dT%H%M%SZ)".json"
```

Use --url for the actual reachable origin when necessary. This diagnostic sends
no messages. It avoids old chat endpoints that mark chats read and uses read=0
on v2. Reports omit tokens, message text, names, JIDs and raw response bodies.
It measures bridge HTTP, not physical UI rendering or recipient delivery. The
included native batch benchmark separately measures synthetic Emacs layout work.
No end-to-end speedup number was established during RC3 preparation.

## VPS and publication entrypoints

After reviewing the local audit evidence, existing guarded entrypoints are:

```fish
fish "$HOME/Downloads/whatsappel-update-3.2.0-rc3/scripts/deploy-ionos.fish" --stage-only
fish "$HOME/Downloads/whatsappel-update-3.2.0-rc3/scripts/commit-and-push.fish" \
    "$HOME/whatsappel" --branch main --commit-only
```

Removing --stage-only explicitly authorizes guarded source installation at
root@securityops.co:5119; it does not restart a guessed service. Host-key checking
stays on. Removing --commit-only requests the existing hidden-token publisher for
the four configured mirrors. The original checkout is not broadly staged. The
publication worktree is ~/whatsappel-publish-3.2.0-rc3. Missing repos are not created
implicitly; non-fast-forward pushes are refused. No commands above were executed
against your VPS or remotes in this iteration. Tags/releases are not automatic.

## Acceptance still required

Run the native gates, then verify ordinary launch and quick launch, mouse target,
focused versus background unread behavior, search, scrolling while images load,
first-load/offline states, drafts across refresh, mpv opening, physical recording,
and recipient receipt of text/image/video/audio/document messages on your actual
bridge. The bridge still has some synchronous administrative/legacy operations;
RC3 does not implement a new event stream or cancel every upstream network call.
