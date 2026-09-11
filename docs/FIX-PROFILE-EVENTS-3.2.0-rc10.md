# RC10: cache-independent profile-event validation

## Exact failure

Both uploaded archives are byte-identical. Both RC9 audit passes contain the same
failure: `test_profiles_http.ProfileHTTPTests.test_invalid_event_group_and_duplicate_keys`.
The assertion for an online group identity expects HTTP 400 and receives 200.
All 79 operator code fingerprints match the retained RC9 candidate. The other
386 full-suite cases and 17 dedicated profile cases passed in the operator's RC9
run; those are not new RC10 test results.

The old bridge reached `(not rec) => ignored` before validating profile fields.
Consequently malformed events received different HTTP status depending on whether
a contact had already been cached. This was an implementation defect, not a stale
label or a missing Guix dependency. Ignored group events did not create records or
prove that a group was displayed online; the defect is validation ordering.

## Change

A side-effect-free `profile-event-change` normalizes supported event fields.
The handler checks that result and timestamp validity before any cache lookup.
Only validated events can reach the uncached/older-event ignored branch.
Mutation occurs under the existing profile mutex, for existing records only.
No outbound I/O, message-store lock or automatic retry is added.

Unknown **valid** direct presence, activity and picture events remain ignored
without retaining records. Invalid group-wide presence and activity, invalid
states/media/chat fields, bad picture-removal types, and invalid timestamps are
rejected before retention checks. Group photographs are still permitted. Earlier
valid state, unread counts, transcript revisions, authentication, worker bounds,
source-isolated installation and privacy consent are preserved.

The original regression assertion remains. Twelve new native test methods cover
cached/uncached identities, flat/native events, accepted group-photo removal,
retention, stale events and unchanged message traffic. Ten new Python tests exercise
bounded failure-summary extraction, redaction, symlinks, oversized or malformed
receipts, and non-executing summaries. See the audit for what actually ran.

## Update / activation

```fish
cd "$HOME/Downloads"
and sha256sum -c whatsappel-update-3.2.0-rc10.tar.gz.sha256
and tar -xzf whatsappel-update-3.2.0-rc10.tar.gz
and fish "$HOME/Downloads/whatsappel-update-3.2.0-rc10/scripts/update-guix.fish" \
    "$HOME/whatsappel"
```

Use the existing local toolchain; do not use sudo or bypass the audit. The cumulative
manifest preserves recorded pre-RC9 anchors. Unrecorded variants/current remote
HEAD are not asserted compatible. Both full native audits must pass before writes.
RC9 installation is not required. A failed attempt leaves installed source alone.

After a successful update, restart the WhatsAppel Emacs instance and the **actual
Guile bridge process**. Code copying cannot update a running process. For an IONOS
bridge, update that matching source separately and use its real activation method;
SSH remains `root@securityops.co:5119` with strict host-key verification. The
existing deploy helper does not guess or restart services, change NPM, relink the
account, or provision provider event subscriptions.

## Fast diagnosis without rerunning tests

Use the updater normally rather than first running redundant audit-only passes.
On any future failed Python gate, the controller now prints the bounded dotted test
identifier. To review existing reports without executing tests:

```fish
python3 scripts/audit-workspace.py --summarize \
    "$HOME/whatsappel-audit-20260910T153309932741Z"
```

That exact path is the RC9 audit supplied in this conversation; substitute the
printed new report directory for later runs. Failure summaries do not print
tracebacks or assertion/subtest values. Original logs remain private and unchanged.
A saved report is not proof of authenticity or a replacement for execution.

## Remaining scope

No redesign, timing claim, Pale integration, cryptographic change, remote writes,
messages or automated service restarts accompany this repair. mpv and RC9 photos,
settings and presence UI remain. Full native tests on Guix and real-session
acceptance remain decisive. Follow the exact backup/rollback instructions printed
on successful installation; rollback refuses newer edits.
