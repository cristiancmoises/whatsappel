# RC7: complete package, Guix updates and four-remote publication

Use the current `README.md` / `README.pt-BR.md` for the command sequence. These scripts
work with editable user-owned source on GNU Guix. They are not a Guix channel package,
`guix package -u`, a system generation change, or a system service manager.

## What is in the full archive

- `source/`: complete retained project source with RC7 changes, tests and documentation.
- `payload/` + `manifest.json`: cumulative managed changes and exact compatible hashes.
- `scripts/`: executable update/commit/push/deploy entry points and their helpers.
- `upgrade.patch`: review delta from the recorded RC6 source, not the cumulative installer.
- `SOURCE_SHA256SUMS`: complete-source index; `SHA256SUMS`: distribution integrity index.
- `evidence/`: real audit logs, separate transaction fixtures and limitations.

Full source contains no .env, sessions, private keys, Git credentials, .git directory,
compiled runtime dependencies or signed release. Optional PQ source is the retained tree.
On **update**, the source snapshot is not imposed on your existing repository: PQ files
used in native tests are copied from your actual checkout and are not managed replacements.

## Existing installation

`fish scripts/update-guix.fish ~/whatsappel` runs exactly two full audit passes and updates
only afterward. Do not run it with sudo. The default is deliberately the existing native
toolchain: your reported Guix environment already has the native tools needed to test this
project. Tool installation is not silently attempted. The local preparation environment
does not contain Guix and cannot establish current package resolution for your channels.

`--check` is read-only compatibility checking. `--audit-only` stages and audits without
installing. Both failure modes retain logs outside the staged source. Missing mandatory
native tools or skipped coverage is not a successful audit. There is no force/bypass flag.
After success, restart the client yourself. RC6-to-RC7 does not change Guile/wuzapi/PQ code.
Cumulative upgrades from before RC2 need the existing bridge restarted to activate RC2.

## Fresh source installation

`--new-install` is explicit and refuses any existing destination, including an empty
directory or a symlink. It validates both complete-source and managed-payload identities,
uses the normal double-full-audit gate, checks the stage again, then performs Linux
`renameat2(RENAME_NOREPLACE)`. A directory created by another process is never replaced.
The fresh path must have an existing writable parent. A failed gate cleans its own private
stage; reports remain as siblings. If desktop registration fails **after** source publication,
the source remains installed and this is reported explicitly. Launcher rollback restores
only launcher entries; it does not delete the fresh source tree. No account is configured.

## Configuration precedence and safety

A complete environment account takes precedence over the private .env account; absent
external account settings preserve Emacs init. Token-only selects documented loopback.
URL-only, empty/invalid tokens or an invalid external origin fail before launch. The Lisp
launch entry point also refuses borrowing an init token for an external URL. The read/upload
workers retain their own origin/token checks. Do not set one origin externally while
expecting a token from another source. These rules do not replace HTTPS, trusted SSH host
keys or protection against hostile same-user processes.

## Remotes

| Key | Repository |
|---|---|
| forgejo-co | https://git.securityops.co/cristiancmoises/whatsappel.git |
| forgejo-com-br | https://git.securityops.com.br/cristiancmoises/whatsappel.git |
| github | https://github.com/cristiancmoises/whatsappel.git |
| codeberg | https://codeberg.org/berkeley/whatsappel.git |

`fish scripts/commit-and-push.fish ~/whatsappel --check` verifies the package and committed
baseline without a worktree or network request (Git checkout required). The default
`--commit-only` creates/reuses `~/whatsappel-publish-3.2.0-rc7`, audits twice in full scope,
then commits only managed paths. It reads raw committed blobs, preserving CRLF and UTF-8
for baseline checks. A nested directory in some unrelated Git repository is rejected.

A normal local update leaves your original working-tree modifications uncommitted.
Publication starts from **committed HEAD** and preserves them; it is a different audited
candidate. This is why it cannot safely reuse the installation's audit receipt.
Publication's commit message describes RC7 rather than carrying RC5's stale message.

`fish scripts/push-four.fish` publishes that clean committed checkout to main on all four
hosts, with per-host hidden token prompts. It never stages or creates another commit.
`--remote forgejo-co` retries one host. Supplying `--branch other` changes the destination
branch. Existing hosted repositories are required unless `--create-missing --visibility
public` (or private) is explicitly supplied. No tags/hosted releases are created. A failed
host does not roll back earlier successful pushes. Reconcile divergence without forcing.
Current remote HEAD and credentials were not checked while generating this package; no
actual hosted mutation is part of local validation.

## IONOS

The retained `deploy-ionos.fish` uses root@securityops.co, SSH port 5119 and strict host-key
checking. `--stage-only` transfers/checks without replacing source. `--target` must be the
actual existing remote source directory. No service restart, Docker rebuild, NPM edit or
session replacement occurs. Desktop changes need a workstation installation too. This
workflow has not been exercised against the real VPS here.

## Rollback

Use the exact backup/rollback command printed by the successful installer. It verifies
hashes before restoring and refuses to overwrite subsequent edits. Retain backups until
native tests plus graphical and live-message acceptance pass. Do not apply the RC6-to-RC7
patch to unknown older source; use the cumulative manifest gate instead.
