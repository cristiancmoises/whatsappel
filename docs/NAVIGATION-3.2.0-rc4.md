# WhatsAppel 3.2.0-rc4 — parser cost and conversation navigation

This is a cumulative release candidate for the retained 3.1, RC1, RC2 and RC3 file
hashes. Current remote HEAD was not verified. Unknown edits are rejected rather
than overwritten. This remains an Emacs desktop client, not a browser app.

## Interface

The root buffer now has **Switch**, **Compact rows / Detailed rows**, and a
**Direct** filter. Direct means non-`@g.us` entries; it does not infer undocumented
WhatsApp entity types. The density toggle changes only the root buffer and lasts
until that buffer closes. It retains query, filter, page limit and row selection.
The first page remains 80 conversations by default.

`C-c C-j` in a conversation or root buffer opens **Switch conversation**; `j` in
root does the same. Completion sees all cached conversations, even beyond the
visible page or active root filter. Names include the JID for disambiguation,
unread counts and a shortened preview are annotations, and completion requires a
known choice. `C-g` cancels without sending or clearing the current draft. The
existing **New** command still accepts a number/JID for a new conversation.
Opening the chosen chat retains its normal asynchronous refresh; gathering the
choices does not contact the bridge. No cache yet means an actionable Refresh
message, not a blocking network lookup. Standard Emacs completion configuration
still applies; no external completion package is required.

`d` in the root toggles density. Detailed rows retain the preview; compact rows
show one name/unread line each. Clicking or Enter still opens the same row.
`C-c C-f` still forwards; `C-c C-b` returns to your draft; `M-g u` retains unread
navigation. These native interactions have supplied ERT regressions but require
native Emacs/GUI validation in this preparation environment.

Unread total changes no longer invalidate the whole root layout. With stable
ordering/filter membership, only the count line and changed visible rows are
replaced. Off-page unread changes update just the summary. Switching into/out of
an Unread-filtered list or a genuine order/width change still uses bounded full
rendering.

## Parsing and security boundaries

The read worker searches plain JSON spans with simple C-engine regular-expression
character classes instead of dispatching a Python iteration per byte. It retains
the 96-level depth check and strict native JSON parser. Escape-dense payloads use
the old linear scan when measured per-match overhead would dominate. This is an
algorithm-selection optimization, not a relaxation of validation.

RC4 also rejects floating-point exponent overflow such as `1e309`, and malformed
percent escapes in read paths. The 4 MiB snapshot and 24 MiB media-response caps,
redirect/proxy refusal, TLS verification, request deadlines and duplicate-key
checks remain. Tokens are passed on worker stdin, not argv or temporary files.

A parser benchmark is not a bridge benchmark: Python process startup, HTTP, Emacs
JSON conversion and native rendering remain separate costs. Small unchanged
snapshots need not become faster. The worker remains one child per read; no
persistent credential-bearing background daemon was added. Legacy Sync/Connect,
forwarding and some other actions still have synchronous paths. The bridge and
wuzapi are unchanged by RC3-to-RC4.

## Verify and install in fish

After placing the archive and its checksum in Downloads:

```fish
cd "$HOME/Downloads"
and sha256sum -c whatsappel-update-3.2.0-rc4.tar.gz.sha256
and tar -xzf whatsappel-update-3.2.0-rc4.tar.gz
and cd whatsappel-update-3.2.0-rc4
and python3 scripts/update-package.py "$HOME/whatsappel"
```

That last step checks compatibility only. Audit the separately assembled candidate:

```fish
python3 "$HOME/Downloads/whatsappel-update-3.2.0-rc4/scripts/update-package.py" \
    "$HOME/whatsappel" --audit-only --full-audit
```

Then install through the native-gated entrypoint:

```fish
fish "$HOME/Downloads/whatsappel-update-3.2.0-rc4/scripts/install-local.fish" \
    "$HOME/whatsappel" --full-audit
```

Both audit passes must succeed before file replacement. Missing native tools are
BLOCKED, not PASS; no force/skip flag exists. The installer prints a private backup
path and exact rollback command. Restart Emacs after success. Restart your actual
bridge service only when upgrading from before RC2; do not guess a service name.
No tokens, configuration, pairing, sessions, NPM or independent pqenv changes are
replaced. The update gate still exercises Guile because cumulative installs can
receive the older RC2 bridge improvement.

Existing guarded deployment and publishing entrypoints remain available:

```fish
fish scripts/deploy-ionos.fish --stage-only
fish scripts/commit-and-push.fish "$HOME/whatsappel" --commit-only
```

These examples stage/check or make a local isolated commit; they do not claim live
deployment/publication. The retained IONOS destination is root@securityops.co:5119.
See the earlier deployment guide for explicit activation and remote options.

## Reproduce measurements and remaining acceptance

On a complete updated checkout:

```fish
python3 scripts/benchmark-read-json.py --samples 11
python3 scripts/audit-workspace.py . --scope full
```

The JSON benchmark alternates RC3-reference/RC4 order, checks output equality,
records every sample and provides p50/p95. No timing threshold makes the audit
flaky. The reference is the retained RC3 parser algorithm, not a remote build.
The separate performance doctor remains available for your real bridge latency.

Before ordinary use, run native compilation/ERT/Guile and verify graphical list
updates at narrow/wide widths, switch/cancel with an unsent draft, image zoom,
mpv, physical microphone capture, account synchronization and actual recipient
delivery. Test approved messages with your own account; do not infer delivery
from an HTTP success. This package neither deploys nor sends messages here.
