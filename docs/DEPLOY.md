# Apply and publish with fish

These commands publish source commits. They do not modify a running WhatsApp
session, start services, publish releases, overwrite tags, or force-push history.
Prerequisites: Git, Python 3.10+, fish, and your configured Git author identity.
Use a normal full clone; shallow clones may need their history deepened.

## 1. Extract and apply

Download `whatsappel-upgrade-3.1.0.tar.gz` to `~/Downloads`. Set `repo` to your
existing WhatsAppel checkout. If you do not have one, first clone
`https://codeberg.org/berkeley/whatsappel.git` into `~/whatsappel`.

```fish
cd ~/Downloads
tar -xzf whatsappel-upgrade-3.1.0.tar.gz
cd whatsappel-upgrade-3.1.0
sha256sum -c SHA256SUMS
set repo ~/whatsappel
fish scripts/apply-update.fish "$repo" upgrade.patch BASELINE_COMMIT \
    --worktree ~/whatsappel-3.1.0 --branch whatsappel-upgrade-3.1.0 --commit
```

Run each command only after the preceding command succeeds. The script verifies
that the recorded baseline is an ancestor of your current HEAD. It creates a
new branch/worktree **at your current commit**, then applies the patch with
three-way merge support. Staged, modified and untracked work in the original
checkout remains there. An existing destination/branch is refused. A conflict
stops in the new worktree and is retained for inspection; nothing is published.

`--commit` uses your configured name/email. Omit it to inspect staged changes and
commit manually. No identity is invented. If your current checkout contains
uncommitted work, that work is deliberately absent from the upgrade commit;
merge it later through your normal workflow. This prevents concurrent edits
from being silently bundled or overwritten.

## 2. Publish to your four hosts

The apply script prints the correct destination branch from your original
checkout. The example below assumes it is `main`; use the printed branch if it
differs. The new local upgrade branch can be pushed to the remote `main` safely.

```fish
fish scripts/publish.fish ~/whatsappel-3.1.0 --branch main --dry-run
fish scripts/publish.fish ~/whatsappel-3.1.0 --branch main \
    --create-missing --visibility public
```

The dry run makes anonymous read-only checks. A missing/private repository is
`UNVERIFIED`, not evidence of an invalid token; it can return a nonzero status.
Run the publication command separately when you intend to create those missing
public repositories. Do not join these two commands with `and` solely on that
basis. Choose `--visibility private` if you intend private destinations; existing
repositories of a different visibility are refused, never changed automatically.

| Selector | Repository | Account |
|---|---|---|
| `codeberg` | `https://codeberg.org/berkeley/whatsappel` | `berkeley` |
| `forgejo-co` | `https://git.securityops.co/cristiancmoises/whatsappel` | `cristiancmoises` |
| `forgejo-com-br` | `https://git.securityops.com.br/cristiancmoises/whatsappel` | `cristiancmoises` |
| `github` | `https://github.com/cristiancmoises/whatsappel` | `cristiancmoises` |

Each token is requested with hidden terminal input. It needs account identity
read (`GET /user`) and repository write; creating repositories also needs
`POST /user/repos` permission. A token limited to one repository may lack account
read or repository creation permission. The publisher verifies the expected
account before mutation. It stores no token in URLs, command arguments, Git
configuration or files; the Git helper uses a private, repository-scoped Unix
socket. Run on your Linux machine with Unix-socket support.

Missing repositories are created empty only with `--create-missing` and explicit
visibility. Existing history must be an ancestor of the local commit; divergent
or newer remote branches are refused. Every successful push is checked by reading
the resulting remote commit. A failure on one host does not roll back earlier
successful hosts. Re-run for a failed destination using, for example:

```fish
fish scripts/publish.fish ~/whatsappel-3.1.0 --branch main --remote forgejo-co \
    --create-missing --visibility public
```

TLS validation stays on; authenticated redirects are refused. HTTP 500 is
reported as a server/proxy failure, not automatically an invalid token.

## 3. Test and use locally

In the new worktree run `make audit`, then the live smoke checklist in USAGE.md.
Preserve the old service working directory until you have reviewed the upgrade.
Existing `.env` is not copied automatically into the new worktree. If you select
that worktree for running the bridge, install your own existing `.env` there at
mode 0600, update the Emacs load-path and service paths, and restart only that
bridge. Your global PQ identity and wuzapi linked-device data stay in their
existing directories. Reverting those path changes returns to the old source;
never reset/clean another process's working tree or delete your keys/session.

For Guix Home, use the corrected example in `contrib/guix-home-whatsappel.scm`.
It reads the two user-owned environment files at runtime and binds wuzapi to
loopback. The systemd unit also loads the existing shell-style `.env` correctly.
Neither service was deployed to your hosts during this audit.

## Resumo em português

Extraia o pacote, ajuste `set repo` para seu clone e execute `apply-update.fish`.
O script cria outro diretório/branch e preserva as alterações em andamento.
Depois execute `publish.fish`, usando a branch de destino mostrada pelo primeiro
script. Digite os quatro tokens quando solicitados no terminal. A opção
`--create-missing --visibility public` cria os repositórios que faltam como
públicos; o script nunca força o push nem muda a visibilidade de um existente.
Conflitos e falhas de servidor são informados individualmente. Não coloque
seus tokens no chat nem dentro dos comandos.
