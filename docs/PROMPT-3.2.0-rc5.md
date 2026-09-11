# WhatsAppel RC5 — executed engineering prompt

Continue from the checksum-verified RC4 artifact, preserving the native
Emacs/Guile/wuzapi architecture, configuration, original media, session/pairing
state, independently newer pqenv code, and every existing send/no-retry boundary.
This iteration prioritizes verifiable correctness, performance and security,
not another unmeasured cosmetic redesign.

## Findings and implementation contract

1. Inspect actual files and reproduce defects before modifying them. Do not
   assert current remote HEAD, recipient delivery, native runtime execution or
   a production deployment. Do not retry the declined CI write, push, create
   branches, contact the VPS, publish, or send a real message.
2. Unify strict JSON parsing for reads and media replies: duplicate keys,
   non-finite numbers, excessive nesting and invalid Unicode must fail closed.
   Treat malformed upload acknowledgements as unknown delivery; never retry
   or misrepresent upstream acceptance as recipient delivery. Bound each upload
   with a total child deadline in addition to socket timeouts.
3. Remove redundant JSON re-encoding from the read child only after the complete
   original response passes validation. Keep a bounded envelope, preserve parsed
   semantic equivalence, and test real subprocess output. Measure isolated CPU
   and allocation costs without claiming end-to-end chat-loading speedups.
4. Replace skip-blind audit exits with structured unittest outcomes, including
   zero-test discovery, subtest failures, module/class skips, expected failures
   and unexpected successes. No unexecuted suite may become a PASS. Retain
   full independent native gates and two completed full audit attempts.
5. Bound audit log sizes, use private new-only report files, stop owned child
   process groups on deadlines/output overflow, redact inherited credential
   variables, and include source/build input identity before/after execution.
   These are developer test hygiene, not a sandbox for malicious source.
6. Installer acceptance must require two complete matching audit reports for the
   exact candidate and selected scope, as well as successful exits. Recheck the
   original bundle and destination inputs; install immutable bytes captured
   from the candidate that passed, not freshly reread unaudited payloads. Reject
   unknown files, edits, symlinks and unsafe permission modes. Preserve rollback.

## Evidence and delivery

Add executable regression tests and real local HTTP/process fixtures. Keep
fixture mocks explicit and limited to the boundary they isolate. Run final
full audits twice without changing code between them; preserve failures,
BLOCKED/PARTIAL statuses and source digests. Attempt native tools only through
available permitted routes; missing tools are never converted to validation.

Deliver the prompt, actual delta, cumulative hash-anchored package, EN/PT-BR
usage/audit notes, raw outcomes, benchmark samples, SHA-256 manifest, fish-safe
check/audit/install commands and rollback evidence. Name the release RC5;
do not overwrite a previous candidate or claim every feature works when
native GUI/Guile/mpv/microphone/WhatsApp acceptance is not executed.
