# WhatsAppel RC6 engineering brief

Continue from the exact RC5 candidate tested by the operator. Use the uploaded
native logs as primary evidence. Deliver a cumulative, content-anchored update,
a reviewable RC5-to-RC6 delta, EN/PT-BR instructions, and reproducible audit logs.

## Diagnose before changing behavior

Extract the operator archive safely. Compare both audit fingerprints with the
retained RC5 source. Identify the exact ERT assertion and SRFI-64 invocation.
Distinguish stale test wording/incorrect test syntax from an application defect.
Do not remove tests, introduce skips, relax the history cap, or disable numeric
configuration validation to obtain a passing result.

Fix history expansion testing through the actual accessible button command,
including bounded history and draft preservation. Give controls stable command
identity independent of translated labels. Correct the named Guile test-error
form; add invalid types/ranges, valid boundaries, defaults, and environment
restoration. Ensure unrelated exceptions cannot stand in for validation errors.

## Scoped performance and usability

Replace polling's scan of every Emacs buffer with visible-frame window traversal.
Exclude minibuffers and hidden/iconified frames, deduplicate buffers, retain
backoff, and prevent one broken buffer starving the others. Keep read-receipt,
message retry, attachment staging, media concurrency, and wire-API semantics.

Test real click/Return button activation plus window discovery, closed buffers,
backoff and error isolation. Do not call a structural scanner native validation.
Claim native timings only when Emacs actually executes.

Print failing test identities/source lines beside native gate failures. Add a
read-only mode to summarize both existing audit passes without rerunning tests.
Bound reads, refuse links and special files, ignore report-supplied log paths,
reject contradictory metadata, and keep raw assertion values/credentials out of
compact output. Preserve the complete original private logs.

## Security and quality

Read launcher .env through one bounded non-following, nonblocking descriptor.
Require private user-owned regular files. Reject malformed UTF-8, duplicate known
settings, control characters, and shell substitutions. Never source .env or put
tokens into argv. Preserve normal Emacs-init configuration when .env is absent.
Exercise actual descriptors, permission modes, FIFOs, size races and redaction.

## Validation and delivery

Run the full audit twice on frozen code. Record exact Python outcomes, runtime
blocks, source hashes, earlier failures, and package checks. Uploaded RC5 passes
are not new RC6 passes. No invented native/GUI/WhatsApp success or certification.

Retain the installer's exact-candidate two-pass gate, locks, private backups,
rollback refusal, local edits, configuration, session and PQ boundaries. Test
recorded cumulative baselines, unknown edits, and final archive extraction.
Use new RC6 filenames; do not overwrite older candidates. Provide one fish install
workflow that performs two full audits before installation, not redundant manual
four-pass instructions. Provide read-only audit and rollback options.

No VPS access, WhatsApp messages, branches, tags, releases, NPM/Docker edits, or
retries of the previously declined CI write. Explain remaining local acceptance.
