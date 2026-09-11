# RC15 — accepted-send recovery and verified activation

## Scope

This is a focused continuation of the checksum-verified RC14 package. The RC14
account-change warning, original late-send assertions, qualified LID destinations,
local send notes, draft preservation, quiet faces and no-automatic-resend policy
remain. It is not proof of actual delivery, photographs, presence or Pale playback.

RC15 catches a failure when scheduling the history refresh **after** a valid send
acknowledgement. It keeps the accepted note, retains newer draft edits, records a
nonsecret warning, and does not let that refresh exception escape the callback.
The unchanged original draft may already have been cleared following acceptance;
that is existing behavior, not a new promise of delivery. Use Refresh to retrieve
history, not Send to retry the same accepted message. Uncertain sends still retain
the draft and an account change still forbids accepting another account's reply.
Four new ERT cases exercise these boundaries. Supplied is not the same as executed.

## One guarded workstation command

Download both package files into ~/Downloads. Use fish, without sudo:

```fish
function whatsappel_update_rc15
    cd "$HOME/Downloads"; or return 1
    sha256sum -c whatsappel-update-3.2.0-rc15.tar.gz.sha256; or return 1
    set -l work (mktemp -d "$HOME/Downloads/whatsappel-rc15.XXXXXX"); or return 1
    tar --no-same-owner -xzf whatsappel-update-3.2.0-rc15.tar.gz -C "$work"; or return 1
    fish "$work/whatsappel-update-3.2.0-rc15/scripts/update-and-activate.fish" \
        "$HOME/whatsappel" --restart-local
end
whatsappel_update_rc15
```

`--restart-local` is explicit authorization to restart **only** the previously
identified user Shepherd service `whatsappel-bridge`. Before installation, the
helper identifies its PID from successful C-locale status output, checks its UID,
direct Guile/source invocation, account token and port in memory, and verifies
that it owns the selected listening socket. Only numeric-loopback HTTP on Linux is
supported for automated activation. Other deployment methods, localhost aliases,
SSH tunnels, root services, unrecognized Guile wrappers or inaccessible /proc data
are refused instead of guessed. No raw environment, tokens or status command text
is printed or stored in the compact report. The existing service itself still
uses its operator-configured launcher; this patch does not rewrite that launcher.

The normal installer stages privately and runs its **two full audits** unchanged.
Failure or partial results cannot authorize an activation. After success every
installed managed file is checked against the package again. A changed service or
account during testing stops activation. Restart is invoked once, then a new
verified source/account/listener process must be observed. Lastly the HTTP endpoint
must identify the expected release and supply its transport API. There is no
automatic pairing, provider restart, callback repair, message send or Git push.

The user-service checks intentionally fail closed. They protect against mistakes,
not an attacker able to modify code/evidence as the same UID. They use Linux /proc
and the English `Main PID:` field of Shepherd status; a changed status format is
refused. Another program may still change services/source after any observation.
A restart failure after successful installation **does not roll source back**:
retain the printed backup/rollback command and the final diagnostic report.

## Modes and outcomes

From the fresh extracted bundle:

```fish
# Read-only: verify managed file contents and make bounded status GETs.
fish scripts/update-and-activate.fish "$HOME/whatsappel" --check

# Update and verify, but do not restart a service.
fish scripts/update-and-activate.fish "$HOME/whatsappel"

# The established source-only updater remains available too.
fish scripts/update-guix.fish "$HOME/whatsappel"
```

Do not combine --check and --restart-local. The helper reads an external account
from private .env/environment as one pair; init-only credentials must not be copied
into arguments and require manual activation through the existing workflow.
No dependency installation, guix pull, profile change or init rewrite is performed.

The private JSON report is written outside the installation and package:

| Phase | Meaning |
|---|---|
| preflight | Source/account/service checks did not complete; read error field. |
| auditing-and-installing | The installer did not complete normally; no helper restart. Consult its audit reports and backup output. |
| files-mismatch | Managed files differ; not a ready installed candidate. |
| restarting-verified-service | Restart was attempted but not fully verified; source may already be installed. |
| installed-not-active | Files match, but expected live version/transport capability is not confirmed. |
| runtime-verified | Files and the observed live version match; **not recipient delivery**. |

Exit 0 means runtime verification succeeded; exit 2 means files or runtime are not
verified; exit 1 is validation/operation failure; 130 is interruption. Presence of
`installed: true` means the source updater returned normally, not that every live
behavior works. `delivery_registration_verified` separately combines the provider
login/connection and callback/subscription results. Even true does not prove
callback network reachability or smartphone delivery. A cached provider state can
also be stale; the report includes its available check age.

Transport support is probed independently of the health advertisement. A valid
/transport/status reply can identify support when /health omits its capability
flag. Conflicting health/transport versions are not accepted as activation. Legacy
/status is read only when the transport endpoint is absent (404/405), never as a
reason to weaken authentication. Responses contain only bounded nonsecret fields.

## Finish in Emacs and test deliberately

Save buffers and fully restart Emacs, including a daemon. Closing an emacsclient
frame alone does not reload the client. The Home/WhatsAppel/telega init is untouched.
Run M-x whatsapp-selection-diagnostics and confirm 3.2.0-rc15. Check delivery
separately. One intentional message to a consenting recipient can then be checked
through its accepted ID, own-history appearance, authenticated receipt and phone.
Do not replay previous uncertain attempts. Retain the exact rollback command.

RC14 -> RC15 does not alter bridge routing/provider logic: its bridge changes are
release identifiers. Earlier cumulative updates include the transport module and
therefore require actual activation. Profile loading and privacy-aware presence
are retained. No remote Idle state is inferred, no new graphical rendering or
throughput measurement is claimed, and Pale remains unimplemented; mpv is an
explicit alternative in Settings. This iteration does not change the video default.

## Validation scope

See AUDIT-3.2.0-rc15.md and evidence. Python tests exercise real files, processes,
loopback HTTP and /proc socket ownership. Synthetic Guile-process metadata and
mocked updater/herd sequences are separately labelled and **not native tests**.
Both full native gates on the actual machine remain required before installation.

References: GNU Emacs Lisp Manual, Sentinels and Asynchronous Processes; GNU
Shepherd Manual, Invoking herd. They explain runtime semantics, not the results of
this package's tests.
