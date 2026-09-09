# WhatsAppel 3.1 upgrade specification

Execute this prompt against the actual checkout. Preserve the Guile + Emacs Lisp + wuzapi architecture, the AGPL-3.0-only license and existing user configuration and identities.

## Goal
Make WhatsAppel approachable as a daily Emacs messenger: a telega-inspired interface, discoverable actions, broader attachments, original-quality image delivery, responsive refresh and an honest, reproducible audit.

## Establish the baseline
Record repository URL, branch and exact commit before editing. Inspect every tracked source area and existing build targets. Read the actual wuzapi contract; do not assume a newer remote version is deployed. Identify gaps in tests, resource limits, credentials, JSON semantics, process invocation, crypto state and installation.

## Implement
1. Offer native clickable controls and keyboard equivalents for opening/filtering chats, composing, attaching, sending originals, refreshing and help. Preserve drafts, pending replies and reading position across refresh. Keep terminal Emacs usable. Do not introduce JavaScript or replace the client with a website.
2. Make refresh asynchronous and nonoverlapping. Avoid repainting identical history and automatically downloading all media repeatedly. Bound caches and disclose remaining synchronous operations and protocol limits.
3. Recognize common image, audio, video, office, archive and text formats. Route unsupported inline media through document delivery. Never rename or mislabel bytes to pretend a codec is supported. Add explicit send-original-as-document behavior: avoid local recompression, preserve bytes, and distinguish preview size from transfer quality.
4. Harden the bridge: reject malformed payloads, bound application inputs, validate config and media, remove token-bearing logs, avoid shell interpolation, deduplicate messages, handle own echoes correctly, preserve live history during sync, and sort timestamps numerically.
5. Audit optional PQ and Org paths. Fix concrete secret-file, path and authentication failures with regression tests. Preserve wire compatibility; do not claim independent cryptographic review or proven security.
6. Supply fish entry points for safely applying an upgrade into an isolated worktree and publishing the resulting commit to Codeberg, both SecurityOps Forgejo hosts and GitHub. Prompt tokens invisibly, keep them out of URLs/argv/git config, verify destination identity, allow explicit creation of missing repositories, and use fast-forward pushes only. Preserve concurrent user work and report each remote independently. Never send tokens to a redirected host.

## Validation and delivery
Run real Emacs ERT, Guile regression/integration checks, Python deployment tests and Rust tests/lints where available. Add a working audit target; missing tools must appear as blocked checks, never passes. Review the final diff and document every material finding and limitation. Provide English and pt-BR usage/deployment instructions, changelog, exact baseline, source archive, patch, checksums and test evidence. Report test counts from actual output. Do not claim live WhatsApp, graphical rendering, dependency advisory coverage, public deployment, or production readiness without the corresponding evidence.

Stop only when the reviewed changes and executable deployment scripts are ready for the user, or a specific unavoidable blocker prevents progress. Leave remote publication to the user via the requested fish scripts.
