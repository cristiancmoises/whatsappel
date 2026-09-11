# RC6: repair the reported native tests, then install safely

## What the uploaded audit actually established

Both RC5 passes reported 19 passing gates and two failing gates. ERT executed
108 cases (107 passed); the Guile suite had 77 passes and one failure. All 62
source-code hashes in those reports match the reconstructed RC5 candidate.
The two failures are test defects: an old `Show older` label assertion and a
named SRFI-64 `test-error` call missing its explicit error-type argument. They
are not evidence that the history cap or zero-value configuration guard should
be disabled. RC6 retains both safeguards and tests the actual button action.

RC6 is a release candidate. The uploaded RC5 results are NOT RC6 results.
See `AUDIT-3.2.0-rc6.md` for the new executed/blocked checks.

## Improvements and boundaries

History expansion tests now find a stable `whatsapp-command` button property,
activate the actual control, verify the expanded history, and retain the draft.
Keyboard Return receives its own regression. Labels can change or be translated
without pretending that a real behavior change passed.

Polling now enumerates visible frame windows, excludes minibuffers and
iconified/hidden frames, and deduplicates their buffers. It no longer scans every
buffer in a large Emacs session. Closing buffers and retry backoff remain
respected. One synchronous refresh exception does not starve another visible
conversation. Exception arguments are not printed in its header. No native
speedup percentage has been measured here. Existing viewport media loading,
mpv, attachment staging and synchronous legacy commands are otherwise unchanged.

The launcher now refuses a group/world-accessible `.env`, symlinks, special
files, oversized reads, malformed UTF-8, duplicate recognized settings, shell
substitution and control characters. It reads one bounded descriptor and never
executes `.env`. A missing `.env` still supports normal Emacs-init configuration.
An insecure existing `.env` is an explicit error, not silent account fallback.
Owner read-only files work too. The launcher does not change permissions itself.
For a regular, user-owned `.env` that needs its permissions corrected:

```fish
chmod 600 "$HOME/whatsappel/.env"
```

This changes access permissions, not token values. The installer preserves the
file and all session/PQ data. A missing file does not need to be created merely
for an existing init-based setup. `--quick` still requires `.env`/environment
credentials because Emacs init is deliberately omitted.

## One guarded fish installation

Download the archive and checksum into Downloads, preserving their filenames.
Use a fresh extraction directory. This command runs TWO full audits, then
installs only when both pass; there is no need to run another two-pass audit
first. Neither missing tools nor skips can unlock installation.

```fish
cd "$HOME/Downloads"
and sha256sum -c whatsappel-update-3.2.0-rc6.tar.gz.sha256
and tar -xzf whatsappel-update-3.2.0-rc6.tar.gz
and fish "$HOME/Downloads/whatsappel-update-3.2.0-rc6/scripts/install-local.fish" \
    "$HOME/whatsappel" --full-audit
```

For an audit without installing, use this INSTEAD of the installation command:

```fish
python3 "$HOME/Downloads/whatsappel-update-3.2.0-rc6/scripts/update-package.py" \
    "$HOME/whatsappel" --audit-only --full-audit
```

The update remains cumulative and accepts recorded exact hashes. RC5 did not have
to be installed after the reported failure. Unknown local edits or alternative
RC3 variants are not overwritten. Configuration, credentials, sessions, wuzapi,
and independently newer PQ files remain outside the payload. The current remote
HEAD was not fetched or asserted to match this retained source.

## Start the application

After successful installation, close/restart the WhatsAppel Emacs instance and
click WhatsAppel in the application menu, or run:

```fish
"$HOME/.local/bin/whatsappel"
```

A configuration/launcher-only check (no messages or bridge connection) is:

```fish
python3 "$HOME/whatsappel/scripts/launch-whatsappel.py" --check
```

RC5-to-RC6 does not change or restart the bridge. An installation predating RC2
also receives that earlier bridge source and needs its actual existing bridge
process restarted. The updater does not guess a Shepherd/systemd/Docker service.
VPS-only source replacement cannot update Emacs already running on the laptop.

## Failures are now visible without rerunning everything

A failing native gate prints a bounded test ID/source line alongside FAIL. The
complete original private log is retained. Compact summaries omit raw assertion
values and backtraces. They are not a claim that arbitrary raw logs are sanitized.
To inspect the operator's existing two-pass audit read-only:

```fish
python3 "$HOME/Downloads/whatsappel-update-3.2.0-rc6/scripts/audit-workspace.py" \
    --summarize "$HOME/whatsappel-audit-20260910T113901839093Z"
```

This correctly returns 1 for that FAILED RC5 audit. It runs no tests, installs
nothing, and never follows a `log` path supplied inside the report. It also
accepts the exact new audit directory printed by the RC6 installer. A summary
reports the saved outcomes; it does not independently attest their authenticity.

## Rollback, deployment, and publication

A successful installer prints its exact backup directory and rollback command.
Use that command instead of guessing timestamps. Rollback refuses newer local
edits. Keep backups until native GUI and live-session acceptance are complete.
No bypass flag, force push, broad staging, token logging, or auto-relink is added.

The existing helpers remain available, but were not executed against production:

```fish
# Upload/check only: root@securityops.co, SSH port 5119, verified host key required.
fish scripts/deploy-ionos.fish --stage-only

# Prepare an isolated commit, without publishing.
fish scripts/commit-and-push.fish "$HOME/whatsappel" --branch main --commit-only
```

The new publication worktree is `~/whatsappel-publish-3.2.0-rc6`. Four-remote
publication retains hidden token prompts and non-force pushes. No remote/VPS
writes or real WhatsApp interactions were performed while preparing this bundle.

## Local acceptance remains necessary

Run native ERT/Guile and full audits on the actual compatible toolchain. Check
mouse/Return on Load older, draft retention, switching/scrolling, unread handling,
mpv windows, microphone Stop/Preview/Send, and confirmed delivery to an explicitly
authorized test recipient. Existing voice/GIF/PQ limitations are unchanged.
Neither a passing HTTP response nor a synthetic decoder test proves delivery.
