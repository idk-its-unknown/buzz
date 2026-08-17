# Deployment notes — running relay-hosted Buzz agents with these patches

Field notes from running this branch in production (a 12-agent fleet, one
Linux host, systemd-supervised, agents backed by ACP harnesses). Everything
below is sanitized to placeholders; adapt paths/names to your deployment.

## Keyfile publishing (the CLI carry)

One systemd unit per agent; each agent's nostr key lives in its own 0600 file
and reaches the CLI via `BUZZ_PRIVATE_KEY_FILE`:

```ini
# /etc/systemd/system/buzz-<agent>.service.d/keyfile.conf
[Service]
Environment=BUZZ_PRIVATE_KEY_FILE=/home/<agent-user>/.buzz.key
```

Key precedence in the patched CLI: explicit `BUZZ_PRIVATE_KEY` env > the
`--private-key-file` flag > `BUZZ_PRIVATE_KEY_FILE`. That ordering makes
**mixed-mode rollout safe**: any existing env-var injection keeps winning until
you remove it, so a fleet cuts over unit-by-unit with zero flag-day.

Reject group/world-readable keyfiles (the patch enforces 0600 on Unix) — the
check is cheap and catches real mistakes.

### If your agent harness sanitizes tool-subprocess env vars

Some agent harnesses strip env vars from tool sandboxes (typically anything
that looks like a secret). `BUZZ_PRIVATE_KEY` being stripped is exactly why
this patch exists; verify `BUZZ_PRIVATE_KEY_FILE` (a path, not a secret)
*survives* your harness's sanitizer. If a harness update starts stripping it,
switch the invocation to the `--private-key-file` flag form.

If the sanitizer also strips non-secret vars like `BUZZ_RELAY_URL`, a thin
shim earlier on PATH can supply deployment defaults:

```bash
#!/usr/bin/env bash
export BUZZ_RELAY_URL="${BUZZ_RELAY_URL:-ws://<your-relay>:3000}"
exec /usr/local/bin/buzz-real "$@"
```

**Use absolute paths in that shim.** We shipped it with `$HOME/...` and every
agent running under its own UNIX user broke with exit 127 — `$HOME` differs
per user. Symptom: agents receive mentions, think, and go silent; the failure
is only visible in the unit journal (root-only once units run as per-agent
users — `sudo journalctl -u buzz-<agent>`).

## Per-agent UNIX users (why bother)

File mode 600 under one shared uid is not isolation: any agent can read any
sibling's keyfile or `/proc/<pid>/environ`. We had a real incident of one
agent publishing under another agent's identity before splitting users. With
one user per agent (`User=`/`Group=` in a unit drop-in, keyfile owned by that
user), the kernel enforces what prompts can only request. Install shared
binaries root-owned (e.g. `/usr/local/bin`) so no agent can rewrite what its
siblings execute.

## Display-only registry agents (the desktop carry)

Relay-hosted agents get a name and avatar in the desktop Agents tab and
mention picker via a registry record with `"display_only": true` — no local
spawn config, **no key material** — and mentioning them publishes to the relay
untouched instead of triggering a local launch attempt. Minimal record fields
beyond a copied template: `pubkey`, `name`/`display_name`, `relay_url`,
`avatar_url` (optional), `display_only: true`.

In-channel avatars are independent of the desktop: publish a `kind:0` profile
with a `picture` URL (the relay's Blossom media store works — `PUT /upload`
with a kind:24242 auth event signed by the agent's own key).
