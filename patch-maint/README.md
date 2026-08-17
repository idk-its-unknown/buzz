# patch-maint — carrying local patches against upstream Buzz

Tooling for anyone running a **patched Buzz build** — a small set of local
commits carried on top of an upstream base — without letting it rot. We use it
to run the patches in this branch in production; it is deliberately generic so
you can reuse it for your own carries.

## The carry model

You are NOT maintaining a fork. You carry a **short, explicit list of commits**
on top of an upstream base, re-applied (cherry-picked) onto each new base. The
authoritative list lives in `patch-commits.json` (copy
`patch-commits.template.json` and fill it in) — scripts read it, humans edit it.

**Drop-on-adoption is the whole point.** Every carry is a liability; the goal
is zero carries. When upstream ships an equivalent, DROP your commit (delete
its entry from `patch-commits.json`) and take theirs — do not "merge" yours on
top. If their variant differs in flag names or behavior, update your deployment
config to match theirs; do not patch Buzz to match you. Every entry's `drop_if`
field names the upstream PR/issue that makes it obsolete.

The carries on this branch:

| carry | what it does | drop when |
|---|---|---|
| `feat(cli): --private-key-file / BUZZ_PRIVATE_KEY_FILE key source` | CLI reads the nostr key from a 0600 file or env-named file instead of a raw env var | upstream merges PR #4096 or resolves #5568 |
| `feat(desktop): display-only registry agents` | desktop stops intercepting mentions of relay-hosted agents; they keep a name/avatar in the picker with no local spawn path | upstream merges PR #3803 / resolves #4834 & #4833 |

## The two scripts

### `check-upstream.ps1` — detection only, run any time

Its only write is `git fetch upstream --tags`. It reports how far behind
upstream you are, scans for **upstream adoption** of your carries (commit-message
grep + a diff scan of your watched files), and writes a dated report under
`reports/`.

| verdict | meaning | exit |
|---|---|---|
| `UP-TO-DATE` | merge-base == upstream/main; do nothing | 0 |
| `BEHIND-CLEAN` | behind, patch areas untouched; rebase at the next release | 0 |
| `BEHIND-CONFLICT-LIKELY` | upstream touched your watched files; budget conflict time | 2 |
| `UPSTREAM-ADOPTED-CHECK-MANUALLY` | adoption-pattern hit; a carry may be droppable | 3 |

Cadence: every upstream `desktop-v*` release, or weekly — whichever comes
first. Run it immediately before any rebase (it does the fetch the rebase
script depends on).

### `rebase-patches.ps1` — the guided re-apply (dry-run by default)

```
powershell -File patch-maint\rebase-patches.ps1 -TargetRef desktop-vX.Y.Z          # dry run
powershell -File patch-maint\rebase-patches.ps1 -TargetRef desktop-vX.Y.Z -Apply   # do it
```

Creates a NEW `<branch_prefix><date>` branch at the target and cherry-picks the
carries in order. **The old branch is never touched** — rollback is
`git switch <old-branch>`. Stops cleanly on the first conflict with
resolve/abort/drop instructions. On success runs the fast gate
(`cargo test -p buzz-cli`) and prints — never auto-runs — the heavy desktop
gates and artifact-rebuild commands.

## Gates

1. `cargo test -p buzz-cli` (repo root — the rebase script runs this one)
2. `pnpm typecheck` and `pnpm test` (from `desktop/`)
3. `cargo check --tests` (from `desktop/src-tauri`; needs the sidecar binaries
   staged per the script's printed instructions)

Windows notes: run cargo from PowerShell, not Git Bash (coreutils `link`
shadows MSVC link.exe); `CARGO_HTTP_MULTIPLEXING=false` helps schannel flakes.

**Baseline your environment failures first**: run the gates once at the CLEAN
upstream base and record any machine-specific failures in
`known_windows_test_failures`. A later gate run passes iff its only failures
are on that list — anything new blocks the rebase. If upstream fixes one,
remove it from the list so it can't mask a real regression.

## Invariants

- Old carry branches are never deleted or rewritten by tooling. Archive
  branches are cheap; keep them until the new branch has shipped.
- `patch-commits.json` is the single source of truth for what you carry.
  Scripts never edit it; a human updates it after each rebase or drop.
- Detection is always safe. Mutation (`-Apply`) requires a clean tree and an
  idle repo.

Deployment patterns for the CLI-keyfile carry (systemd units, key isolation,
mixed-mode rollout) are in `DEPLOYMENT-NOTES.md`.
