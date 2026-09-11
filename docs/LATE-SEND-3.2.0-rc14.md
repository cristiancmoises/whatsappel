# RC14: restore the stale-account send warning

## Why RC13 did not install

The operator's two-pass summary names only
`wa-rc3-late-send-after-account-change-retains-draft`. The updater refused
installation. The subsequently executed Shepherd restart started the previously
installed files; it did not activate the candidate in the audit directory.

The original test makes two assertions: the draft text remains, and
`whatsapp--last-error` is non-nil. Inspection of the exact retained RC13 archive
shows the stale-response branch marks its local note unconfirmed but never sets
that error state. RC14 restores the missing warning in production code. The original
test and its assertions remain byte-for-byte unchanged. Without the user's full
ERT trace or a native execution here, this is a source-grounded diagnosis matching
the reported test, not a claim of a locally reproduced Emacs traceback.

## Precisely scoped change

A late callback from another account/conversation keeps the draft, keeps the
attempt unconfirmed, records a constant nonsecret warning, and does not refresh
history or retry the message. A duplicate callback is still ignored. Ordinary
same-account acceptance, newer draft protection, recipient normalization and strict
provider-ID validation are unchanged. LID preservation and quiet UI styles from
RC13 remain. No performance enhancement, complete delivery fix, Pale implementation
or new provider behavior is advertised in this repair.

Six new ERT cases check token/URL changes, no private error data, unchanged
text/point/marker/reply/undo, edited drafts, no duplicate resend or callback
processing, owner-buffer isolation, and normal-account acceptance. See the audit
for actual execution limits; a supplied test is not a passing native test.

## One function: full audit, install, verify, then activate

Download both the RC14 archive and checksum into ~/Downloads, keeping their names.
Run the following in fish, without sudo. Existing downloads/backups are retained.
Do not run a separate restart command after a failed installation.

```fish
function whatsappel_update_rc14
    set -l target "$HOME/whatsappel"
    cd "$HOME/Downloads"; or return 1

    sha256sum -c whatsappel-update-3.2.0-rc14.tar.gz.sha256
    or return 1

    set -l work (mktemp -d "$HOME/Downloads/whatsappel-rc14.XXXXXX")
    or return 1
    tar --no-same-owner -xzf whatsappel-update-3.2.0-rc14.tar.gz -C "$work"
    or return 1
    set -l bundle "$work/whatsappel-update-3.2.0-rc14"

    # Failure stops this function before any service restart.
    fish "$bundle/scripts/update-guix.fish" "$target"
    or begin
        printf '\nUpdate stopped. This function has NOT restarted the bridge.\n' >&2
        return 1
    end

    # Verify installed payloads before restarting the known local service.
    python3 -c '
import hashlib, json, sys
from pathlib import Path
bundle, target = map(Path, sys.argv[1:])
spec = json.loads((bundle / "manifest.json").read_text())
for entry in spec["files"]:
    path = target / entry["path"]
    if (path.is_symlink() or not path.is_file()
            or hashlib.sha256(path.read_bytes()).hexdigest() != entry["after"]):
        raise SystemExit("Stopped: installed payload verification failed; no restart.")
print("Installed RC14 managed files verified.")
' "$bundle" "$target"
    or return 1

    herd --log-history=0 status whatsappel-bridge
    or return 1
    herd restart whatsappel-bridge
    or return 1
    herd --log-history=0 status whatsappel-bridge
    or return 1

    printf '\nSave your buffers and fully restart Emacs, including its daemon.\n'
    printf 'Then run M-x whatsapp-selection-diagnostics and confirm 3.2.0-rc14.\n'
end

whatsappel_update_rc14

```

The existing updater retains its two exact-candidate full audits, before/after
fingerprints, private backups, immutable payload and unknown-edit refusal. The
verification after installation compares managed files to the manifest before
activation. It does not verify the whole operating system or live phone delivery.

This function only restarts the local user `whatsappel-bridge` service previously
identified by the operator as running ~/whatsappel/whatsappel.scm. It does not restart
wuzapi, reset pairing, repair a callback, change presence, send messages or push code.
A service failure after installation does not roll source back automatically:
keep the printed backup and use the actual diagnostic before further action.

The bridge changes from RC13 to RC14 are version labels only. Cumulative upgrades
from older installations include the previously missing transport module, so both
bridge activation and a complete Emacs restart are still required. An emacsclient
frame is not a replacement daemon. Keep the existing Home/WhatsAppel/telega init.

## Verification, uncertainty and rollback

After restart use `M-x whatsapp-selection-diagnostics`: loaded version must be
3.2.0-rc14. Check delivery separately through the existing connection panel. Do not
resend all previous uncertain attempts: acceptance, returned history and recipient
delivery are different observations. New native audit outcomes, real photographs,
incoming callback reachability and real receipts remain unverified until observed.

Use the exact rollback command printed by a successful installation. Rollback
refuses newer edits. Unknown source variants remain unsupported, not force-patched.
No external pushes, actual service restarts or real messages occurred in preparation.
