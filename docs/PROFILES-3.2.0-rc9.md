# RC9 — native profile workspace

**Candidate, based on the retained RC8 package.** Current remote HEAD, the user's
installed provider version, real-account behavior and native graphical acceptance
are not asserted verified. Use AUDIT-3.2.0-rc9.md for actual executed results.

## Visible changes

The existing Emacs workspace now has buffer-local near-black/cyan faces (or the
current editor theme), locally disabled code line numbers, reserved avatar gutters,
a contact header, contact-details and settings panels. Comfortable/compact rows,
the existing sidebar and narrow-window behavior are retained, not replaced by a
new window manager. Changing selection preserves row characters and the RC8
compose-first/deferred-read path. No new automatic PQ decryption is introduced.

Click a row to open its conversation; click its avatar or **Contact info** to see
profile details. `i` in the root and `C-c i` in a chat open details. `q` closes the
panel. **Larger photo** explicitly requests a 256-pixel prepared preview; this is
not a full-resolution image download or an original-photo saver. A read-only
`M-x whatsapp-profile-diagnostics` reports version, capability state, job counts,
cache counts and account-scoped consent without IDs, names, URLs or tokens.

**Settings** offers photos on/off, cache clearing, presence consent, cyan/current
palette, and font scaling for app buffers. **Emoji** / `C-c e` inserts a chosen
Unicode character into the draft, never sends it. Existing Send/Attach/Record/
Preview/Cancel flows, Enter/C-j and Forward remain. No new PTT, GIF-loop, media
cryptography, pin/mute controls, Status stories or browser frontend are claimed.

## Profile and presence contract

| Feature | Implementation / prerequisite |
|---|---|
| Photo thumbnails | Authenticated backend `POST /user/avatar`, Preview=true; 96px PNG worker output, displayed smaller. JPEG/PNG at exact HTTPS `pps.whatsapp.net` only. Other hosts/formats fall back rather than loosening policy. |
| Larger contact photo | Explicit Preview=false lookup; still transformed to bounded 256px PNG. |
| About | Explicit details lookup through `POST /user/info`; `Users[JID].Status` means About, not stories or online state. |
| Presence | Observed flattened wuzapi Presence or native whatsmeow Presence event. Online/offline expires to unavailable after at most 60s without fresh evidence. |
| Last seen | Only authorized positive backend timestamp while observed offline. Hidden/zero/future values do not become inferred timestamps. |
| Typing/recording | Typed ChatPresence events, independently expires after 8s; paused is not offline. |
| Groups | Photo lookup supported by identity grammar; header says Group conversation, never group-wide online. |
| Picture changes/removal | Typed Picture events increment a separate revision and invalidate pending/cached images. Actual forwarding depends on provider version/subscription. |
| Remote Idle/Away | Unsupported: never inferred from silence, a last message or a delivery receipt. |
| LID vs phone | Kept distinct; phone suffix normalization only. This iteration does not invent PN/LID mappings absent from the backend. |

These are implemented contracts, not evidence that the installed provider exports
every operation. `404`, `405` and `501` become a feature-unavailable result. Privacy
restrictions and temporary failure are not interpreted as contact blocking.

### Presence is explicit opt-in, not an online announcement

Click **Settings → Presence consent** and review the confirmation. Consent is scoped to the
current account and Emacs session; setting a customization boolean alone does not
subscribe. Only a selected, visible direct contact is subscribed. The bridge caps
attempts to 16 distinct identities per transport epoch and one attempt/contact per
five minutes. No `POST /user/presence` or outgoing typing route is called.

The provider may require *your own account* to be available to supply presence;
some wuzapi versions announce availability on connection. RC9 does not change
that pre-existing provider behavior or force it online. Disabling RC9 consent
stops future subscriptions; it does not invent an upstream unsubscribe API.

**Event forwarding is an operator prerequisite.** Preserve existing Message and
other webhook subscriptions and add only event names supported by your installed
wuzapi build (Presence, ChatPresence and Picture where forwarded). Existing
`WHATSAPPEL_SUBSCRIBE` is not silently rewritten. Changing an environment setting
alone does not retroactively reconfigure an already connected backend. Do not
re-pair, reset sessions or call Connect merely to get cosmetic indicators. No
live provider configuration is mutated by this package. Until authorized events
arrive, **Status unavailable** is the correct result.

Timestamped older events are ignored. Events without timestamps use receipt order;
they cannot prove a remote clock ordering. Presence history is not persisted.

## Bounded work and privacy

A separate worker receives control on stdin. At most two profile tasks run, with
16 queued and 12 visible identities per snapshot. Background enrichment waits
while visible normal reads/sends are pending. Guile uses its own two-slot metadata
pool, not the message-store lock, and completed job results are single-consumer,
authenticated and expire after 30s. Normal `/chats` and `/chat` responses contain
no new photo bytes, and presence does not modify transcript revisions/unread state.

Photos use one vetted DNS result with certificate-checked TLS for the original
exact hostname; private/link-local/loopback/multicast/transition addresses and
redirects are refused. CDN headers contain no account tokens/cookies. Input is
limited to 2MiB, 4096 per edge and 4 million pixels, then transformed by an owned
FFmpeg process with a six-second timeout and CPU/address-space limits. This is a
risk reduction, **not a complete codec sandbox**. Normalized 96/256px PNG output
is bounded before a deferred native decode. The worker has a 20s normal overall
deadline; Emacs adds a 21s parent timeout. DNS/native calls can defer Python signals.
Guile's retained HTTP client cannot forcibly cancel a stalled upstream call; a
hung call can occupy a slot, but profile jobs do not hold the message-store mutex.

Client metadata is capped at 128 entries; prepared image cache at 32 entries,
4MiB encoded bytes and 1 million source pixels. A native display library or
buffer-held image reference can use additional memory; these are not process RSS
ceilings. Photos expire after 120s, legitimate removals drop displayed references,
and epochs/account changes reject late results. No photo cache is persisted.
**Clear profile cache** removes app-owned in-memory references and cancels jobs;
it is not secure erasure of process memory and also clears session consent.

## One-command update on GNU Guix

Download the archive and its matching checksum into Downloads. Do not use sudo.

```fish
cd "$HOME/Downloads"
and sha256sum -c whatsappel-update-3.2.0-rc9.tar.gz.sha256
and tar -xzf whatsappel-update-3.2.0-rc9.tar.gz
and fish "$HOME/Downloads/whatsappel-update-3.2.0-rc9/scripts/update-guix.fish" "$HOME/whatsappel"
```

It stages the exact candidate, runs **two full audits**, and installs only when
both required reports pass. Unknown edits, failures, skipped required tests and
missing runtimes stop replacement. There is no bypass. It preserves `.env`,
sessions, independent PQ files, unrelated local work and rollback backups. Do not
manually copy `source/` over the installation. `--check` is compatibility-only;
`--audit-only` runs both passes without installation; `--new-install` is explicitly
for a nonexistent target. Neither Guix channels nor profiles are changed.

### RC9 changes the bridge too

After installation succeeds, restart **both Emacs and the actual existing Guile
bridge process**. This update does not guess your Shepherd/systemd/Docker service,
restart wuzapi, expose a new port, change NPM or log you out. Keep the new sibling
`whatsappel-profiles.scm` alongside `whatsappel.scm`; `whatsapp-profiles.el` and the
Python helper are also required. The launcher prints RC9 through diagnostics.

When the bridge is on IONOS, update that source separately with the included
`fish scripts/deploy-ionos.fish --stage-only`, then the explicit actual target
path for deployment. The defaults are `root@securityops.co:5119` and strict
host-key verification. Source transfer cannot activate new code in a running
process. An old bridge returns unsupported profile capability; messages retain
legacy behavior. Do not change SSH trust or unrelated running services to force it.

### Publication, not automatic deployment

```fish
fish scripts/commit-and-push.fish "$HOME/whatsappel" --branch main --commit-only
and fish scripts/push-four.fish
```

These retain the isolated `~/whatsappel-publish-3.2.0-rc9` workflow and hidden-token,
non-force pushes to the existing four whatsappel repositories (Codeberg berkeley;
GitHub / both securityops forges cristiancmoises). No push was performed while
preparing RC9. Repository creation is opt-in; no tags/releases are created here.

Use the **exact rollback command printed after successful installation**, then
restart Emacs and the bridge. Newer edits are refused rather than overwritten.

## Native and graphical reproduction

The full audit includes the new native ERT suite, real Guile profile HTTP suite,
and cached-selection benchmark for 1,000 and 10,000 synthetic summaries. The
100ms p95 target is printed with raw samples; it is not an achieved number or a
universal guarantee. Thumbnail timings are separate local FFmpeg work.

For graphical fixture screenshots, from a complete source tree in a *separate*
Emacs process:

```fish
set -l output (mktemp -d "$HOME/Downloads/whatsappel-ui-rc9.XXXXXX")
and env WHATSAPPEL_UI_OUTPUT="$output" emacs -Q -L . -l tests/profiles-ui-smoke.el
```

It requires graphical Emacs with `x-export-frames`. Captures are labelled OFFLINE
SYNTHETIC DEMO; fixture actions prohibit network. No screenshot is supplied as
executed evidence when that runtime is unavailable. Headless ERT, actual frame
exports, live provider access, physical microphone/mpv and recipient delivery are
separate acceptance checks. Keep the backup until they pass on your installation.

## Primary implementation references

Inspected 2026-09-10; upstream main documentation is not a pinned installed version.
- https://github.com/asternic/wuzapi/blob/main/routes.go (POST methods take precedence over stale GET examples)
- https://github.com/asternic/wuzapi/blob/main/handlers.go
- https://pkg.go.dev/go.mau.fi/whatsmeow/types/events
- https://pkg.go.dev/go.mau.fi/whatsmeow
- https://www.gnu.org/software/emacs/manual/html_node/elisp/Asynchronous-Processes.html
