# WhatsAppel 3.2.0-rc5 — quality, performance and security

## What this iteration changes

This iteration changes Python workers, audit/installation tooling, tests, build
entrypoints and documentation. Emacs source changes only its release identity;
there is no new graphical interaction or Guile/wuzapi/pqenv implementation here.
Existing RC4 compact/detailed rows, Direct filtering, cache-only switching, image
viewer and mpv/voice flows are retained, not newly certified.

Read and upload workers load `bridge_protocol.py` beside their own installed
script. It rejects duplicate JSON keys, excessive nesting (over 96), nonfinite
numbers including exponent overflow, invalid UTF-8 and unpaired Unicode surrogates.
Valid multilingual strings and surrogate-pair escapes remain supported. Existing
caller-specific size limits remain; the upload reply cap is 1 MiB.

A strict parser is not a complete application schema validator. A valid upstream
acknowledgement means upstream acceptance, not recipient delivery. A malformed,
lost or contradictory reply remains uncertain. Inspect the conversation before
manually retrying: a timeout cannot establish that the message was not sent.

On the owned POSIX main-thread worker, the upload POST and reply share a total
requested deadline (1–120 seconds) as well as socket timeouts. File reading and
payload construction occur before that deadline. Other platforms/threads require
socket and parent-process limits; this is not portable thread cancellation.
Some native calls can defer Python signal handling; retain parent cancellation.
No automatic retry, redirect following, proxy environment usage or TLS bypass is
introduced. Tokens remain on stdin, not command arguments.

After a complete read response passes framing, size, deadline, strict parsing and
existing route-shape checks, its original JSON bytes are placed directly in the
worker envelope. This avoids decoding-and-encoding the object a second time;
validation is not skipped and untrusted error-response bodies are not forwarded.
Whitespace and escape representation can differ from older compact envelopes,
while parsed values remain equivalent. The parent still performs its own parsing.

## Audit semantics and resource limits

`make audit` invokes the full structured controller. `make check-python`,
`make check-read-api` and `make check-responsiveness` use the skip-aware runner.
The runner returns 0 for complete PASS, 1 for FAIL, and 2 for PARTIAL. Skips and
expected failures are never successful tests; zero discovery fails. Actual observed
successes are counted, including correct handling of class skips and subtests.

The controller captures each command into an exclusive private log (0600), with
an 8 MiB output ceiling and a 600-second wall deadline. Limit/deadline violations
fail the gate. POSIX child process groups are cleaned up; detached processes that
create their own sessions are outside this mechanism. Audit directories must be
new and outside the checkout. Common token/password/key environment variables are
removed from test subprocesses. This is accidental-exposure reduction, not a
sandbox: repository tests remain trusted local code with the current user's rights.

Each report contains a run identifier, scope, exact ordered gates, structured test
counts and before/after source SHA-256 maps. Source/build inputs include Scheme,
Emacs Lisp, Python, Rust, Makefile, shell and Go files, not secret configuration.
Symlink source directories and nonregular source files are refused.

## Install with fish

Download the archive and its checksum into Downloads. The bundle supports only
explicitly recorded per-file hashes from the retained 3.1/RC1/RC2/RC3/RC4 chain.
There were multiple earlier RC3 variants; an unrecorded variant is correctly
refused. Current Codeberg/GitHub HEAD is not asserted by this package.

```fish
cd "$HOME/Downloads"
and sha256sum -c whatsappel-update-3.2.0-rc5.tar.gz.sha256
and tar -xzf whatsappel-update-3.2.0-rc5.tar.gz
and cd whatsappel-update-3.2.0-rc5
and python3 scripts/update-package.py "$HOME/whatsappel"
and python3 scripts/update-package.py "$HOME/whatsappel" --audit-only --full-audit
```

The first updater invocation checks only. The second builds a private candidate,
runs both full audit passes and never installs. Missing native tools or partial
coverage prevent success. Required components include Python 3.10+, Emacs 28.1+,
Guile with JSON support, fish, mpv and FFmpeg; full scope additionally needs a
compatible Rust/Cargo toolchain. Presence is not proof of module/codec compatibility.

After those checks succeed:

```fish
fish "$HOME/Downloads/whatsappel-update-3.2.0-rc5/scripts/install-local.fish" \
    "$HOME/whatsappel" --full-audit
```

The installer repeats its mandatory checks. It freezes managed candidate bytes
before testing, verifies both distinct reports and the exact expected gate set,
compares code hashes with the staged candidate, rechecks the bundle, documents and
unchanged destination inputs, and installs the frozen bytes. A changed README,
newer PQ edit or missing receipt cannot be replaced by a successful exit code.
Source hashes and receipts are consistency evidence, not digital signatures or a
security boundary against a malicious process running as the same user.

A successful install prints its private backup and exact rollback command. Keep
that backup. Rollback refuses to replace files edited after installation. Existing
configuration, pairing/session data, original media and independently newer pqenv
source are not overwritten. Unknown source hashes stop the operation.

Restart Emacs after successful installation. RC4-to-RC5 does not change the bridge.
An upgrade from before RC2 also includes the previous RC2 bridge update; restart
your actual existing bridge service then. The installer does not guess service
names, rebuild Docker, change NPM or relink WhatsApp.

## Existing deployment and publication entrypoints

These operate only when you run them after native validation. They have not been
executed against the real VPS or remotes as part of this delivery.

```fish
fish scripts/deploy-ionos.fish --stage-only
# Supply the actual source path for installation; the path below is only an example.
fish scripts/deploy-ionos.fish --target /root/whatsappel
fish scripts/commit-and-push.fish "$HOME/whatsappel" --branch main --commit-only
fish scripts/commit-and-push.fish "$HOME/whatsappel" --branch main
```

IONOS transport retains `root@securityops.co:5119` and verified host keys. The
isolated publication worktree is `~/whatsappel-publish-3.2.0-rc5`, preserving dirty
work in the original checkout and excluding it from the release commit. Hidden
prompts remain for Codeberg, GitHub and the two SecurityOps forges; no force push,
implicit public repository creation or token-in-URL behavior is introduced.
VPS client-source changes alone do not update the Emacs UI on a separate laptop.

## Measurement and release boundaries

`python3 scripts/benchmark-read-envelope.py --samples 5` measures only second-pass
JSON envelope construction using an in-memory counting sink, plus a separate
streaming-SHA benchmark. It excludes validation, IPC transfer/scheduling, Python
startup, HTTP, Emacs rendering and WhatsApp delivery. The existing parser benchmark
still runs independently. No whole-app latency or RSS guarantee follows.

The retained read-only `doctor-performance.py` measures the real bridge without
sending a message or marking a chat read. Actual graphical click/scroll/zoom,
physical microphone, mpv windows, QR pairing and recipient delivery remain manual
acceptance gates. Full native test execution and current dependency advisory
checking are not replaced by Python, structural Lisp checks or synthetic receipts.

See `AUDIT-3.2.0-rc5.md` for observed results, failures and blocked gates.
