# RC17 — invalid response must preserve the draft and reply

## Diagnosis

The operator's pasted RC16 output names
`whatsapp-workspace-send-failure-retains-draft-and-reply` as the only failed gate's
failed ERT identifier in both runs. The activation report explicitly says
`installed: false`, `restart_attempted: false`, `service_restarted: false` and
`phase: auditing-and-installing`. No subsequent RC16 installation is assumed.
The 7 missing and 19 changed paths were candidate-versus-installed differences,
not a permission error or evidence of 26 corrupted files.

The unchanged test invokes the normal send callback with `(200 . :invalid-json)`.
RC16 correctly declines to accept that response. Its new failure-message code
then runs `(assoc "error" (cdr result))`: the second argument is the symbol
`:invalid-json`, not an association list. That violates the expected list type and
can raise a callback exception before the draft/reply assertions are reached.
The operator did not supply the full RC16 ERT traceback. This is a diagnosis from
the exact retained source and named test, not a claimed reproduction in native
Emacs here. See the audit for the actual runtime availability.

## Minimal production correction

Read the body with `cdr-safe`; access the error field only when `proper-list-p`
confirms it is a proper list. A sentinel, scalar or absent failure body uses:

> Unconfirmed send. Draft retained; check recipient before retrying.

The same existing five safe error messages remain allowlisted. Raw server text
and credentials are not displayed. The callback clears the pending flag but
preserves draft text, newer edits and reply context, retains an unconfirmed local
note and does not resend or start a success-only history refresh. The valid-send
branch, recipient agreement, ID validation and late-account guards are unchanged.
The original workspace-tests.el and responsiveness-tests.el remain byte-identical.

This fixes failure *handling*. It does not turn invalid JSON into acceptance,
make a recipient receive a past attempt, or alter the provider/Guile routing.
Bridge changes in this candidate are release labels only. Earlier cumulative
updates still require their updated bridge modules to be installed and running.

## One guarded update

Download the complete archive and its checksum into ~/Downloads. Use fish, not
sudo. Extract to a fresh directory. The activation wrapper remains unchanged:

```fish
function whatsappel_update_rc17
    cd "$HOME/Downloads"; or return 1
    sha256sum -c whatsappel-update-3.2.0-rc17.tar.gz.sha256; or return 1
    set -l work (mktemp -d "$HOME/Downloads/whatsappel-rc17.XXXXXX"); or return 1
    tar --no-same-owner -xzf whatsappel-update-3.2.0-rc17.tar.gz -C "$work"; or return 1
    set -l bundle "$work/whatsappel-update-3.2.0-rc17"
    # Run the exact reported regression first, without loading your init or account.
    emacs -Q --batch -L "$bundle/source" \
        -l "$bundle/source/tests/workspace-tests.el" \
        --eval "(ert-run-tests-batch-and-exit 'whatsapp-workspace-send-failure-retains-draft-and-reply)"
    or return 1
    fish "$bundle/scripts/update-and-activate.fish" "$HOME/whatsappel" --restart-local
end
whatsappel_update_rc17
```

The first ERT command is an isolated synthetic callback test, not a real message.
The normal updater then stages using your installed unchanged inputs, runs both
full native audits, installs only on complete success, verifies disk/source/account
and the known listening local user service before any restart, and checks the
resulting runtime. Failure stops the chain. Do not restart separately after failure.
This does not pull channels, change your Guix profile, rewrite init/.env, reset
sessions, repair callbacks, or push. Never copy source/ over your installation.

`--restart-local` authorizes only the verified local user service whatsappel-bridge.
A different source, account, listener, inaccessible /proc or remote endpoint is
refused, not guessed. The known updater's two-pass policy is not relaxed.
RC16 need not be installed first: explicit older cumulative content anchors remain.
Unknown local edits or unrecorded variants are not overwritten.

## After success

Save buffers and fully restart Emacs, including a daemon. Do not hot-load the
whole init over pending sends. Confirm `3.2.0-rc17` using
`M-x whatsapp-selection-diagnostics`. Preserve Home / WhatsAppel / telega.
Keep the exact rollback command and backup printed by installation. A restart
failure after successful source replacement is reported separately; source is not
automatically rolled back over live state.

Review delivery separately. Never bulk resend previous unconfirmed messages.
Provider acceptance is not recipient delivery. Photos, line cleanup and unavailable
Pale playback retain RC16 behavior; no new GUI or performance claim accompanies
this focused fix. Approved real-account testing remains outside the automatic audit.
