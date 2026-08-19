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

### Promoting a locally-set avatar to the agent's wire profile

The desktop's avatar editor for display-only agents changes only THIS device's
registry (by design — the desktop holds no agent keys). The upload it performs
does land in the relay's media store, though, so the image URL it saves is
already fleet-reachable. To make it the avatar every client sees, publish it
into the agent's `kind:0` from the agent's host, signed by the agent's own key:

```bash
BUZZ_PRIVATE_KEY_FILE=/home/<agent-user>/.buzz.key \
  buzz users set-profile --avatar "<the media URL>"
```

`set-profile` is read-merge-write (verified in `commands/users.rs`): a lone
`--avatar` update preserves the existing display name, about, and NIP-05.

Zero-shell variant: the agent can run that command on itself — it has the CLI
and its keyfile in its tool sandbox, the same machinery it publishes messages
with. Mention the agent and ask it to update its avatar to the URL.

Related desktop setting: enable "Agent-managed profiles" (Settings →
Experiments) so the desktop's profile reconciliation does not restore its
local copy over what the agent publishes.

### Instructions for display-only agents (read = kind:0 about, write = mention)

A display-only record's `system_prompt` never reaches the remote harness —
the agent's real instructions live in its own config on its host (its
SOUL.md / workspace instructions file). The honest loop mirrors the avatar
pattern; the agent is the only writer of its own brain:

- **Read**: each agent publishes its instructions file into its kind:0
  profile `about` (`buzz users set-profile --about "$(head -c 8000
  <instructions-file>)"`, signed with the agent's own key — read-merge-write,
  so name/picture survive). The desktop shows this as "Current instructions
  (published by the agent)" in the instance-edit dialog and as the profile
  bio.
- **Write**: the dialog's "Request an instructions change" box is a draft.
  "Copy change request" produces a paste-ready message; mention the agent in
  its channel and paste. Install a standing protocol section in each agent's
  instructions file telling it to apply such requests to the file and then
  republish its `about` — after which every client shows the new brain.

Both halves are automated by a fleet-side script (in this deployment:
`30-publish-brains.sh`) that appends the protocol section (marker-guarded,
idempotent) and performs the initial publish for every agent.

### Phantom persona twins (fixed; one-time cleanup for stores that predate it)

Before the gate in `migration/backfill.rs`, every keyed record with no
persona link — display-only records included — got a key-less definition
manufactured at boot (slug = the agent's pubkey) and was linked to it. For
display-only records that definition is a **phantom twin**: a persona card
whose lifecycle actions (duplicate / delete / deactivate) target nothing the
desktop manages. The twins were also published as kind:30175 events under the
desktop owner's key, so deleting them locally was not enough — the relay
would re-deliver them.

The fix is three gates that land together:

- the boot backfill skips `display_only` records entirely;
- the inbound kind:30175 reconcile drops any event whose d-tag is a local
  display-only record's pubkey (a stale twin echo from the relay);
- the inbound kind:30177 merge never re-applies a `persona_id` onto a
  display-only record (stale pre-gate events still carry the twin link).

Display-only records now render in their own "Remote agents" group in the
Agents tab, with an Edit action that opens the full instance-edit dialog.

Stores written by pre-gate builds still hold the twin rows. Run
`cleanup-phantom-twins.py` (this directory) ONCE, with the app closed and the
patched build already deployed: it backs up `managed-agents.json`, drops the
twin definitions, nulls the display-only records' `persona_id`, and deletes
the twins' retained kind:30175 rows from every scoped retention database —
a retained row left `pending_sync=1` would otherwise be republished to the
relay by the flush loop on next launch. It is idempotent and verifies its
own writes.

Stale twin events already on the relay cannot re-enter the local persona
store (the inbound gate drops them), but a re-delivered echo does leave one
inert retained row per coordinate in the retention database (sync-head
bookkeeping, `pending_sync=0` — never republished, nothing rendered). For a
fully clean relay, delete the kind:30175 events whose d-tag is a fleet agent
pubkey from the relay's database.

## Mobile pairing on a compose-deployed membership relay

A relay deployed from `deploy/compose` advertises NIP-43, so the desktop's
pairing discovery resolves the legacy `<relay>/pair` path — which nothing
serves (the `buzz-pair-relay` sidecar is wired up only in the helm chart).
Pairing dies with `WebSocket connection failed: HTTP error: 404`, and the
`MainRelay` fallback cannot work on a membership relay: pairing signs with
ephemeral throwaway keys, and NIP-42 AUTH rejects them
(`restricted: not a relay member`) before they can subscribe. Upstream
tracking: block/buzz#2734 (compose bundle fix: PR #2736).

Deployment shape used here:

- `buzz-pair-relay` built from this branch (it also ships inside the relay
  image at `/usr/local/bin/buzz-pair-relay`), run as a hardened systemd unit
  on the relay host, bound to a public port. The crate now arms hyper's 30s
  header-read timeout in-binary (this branch), so a proxyless bind is not
  left with unbounded pre-upgrade sockets; a per-IP new-connection rate
  limit (`ufw limit`) fronts the port. Note the rate limit budget (~6 new
  connections per 30s per IP) is shared by the desktop and a phone on the
  same NAT — enough for normal pairing (2 connections per attempt), but
  rapid-fire retries can trip it; if pairing suddenly gets connection
  refusals after several attempts, wait 30s.
- The relay's own `BUZZ_PAIRING_RELAY_URL` env var (compose `.env`) makes
  NIP-11 advertise `pairing_relay_url`, so stock desktops discover the
  sidecar with no client configuration.
- Belt-and-braces (this branch): the desktop honors a client-side
  `BUZZ_PAIRING_RELAY_URL` env override consulted before the NIP-11 probe —
  useful when the relay's config is out of reach. Set-but-invalid values
  fail pairing loudly rather than silently falling back. The desktop reads
  it at pairing time from its process environment, so a change takes effect
  only after the app is relaunched.

Mobile caveat: release builds of the mobile app require an `https://` relay
URL at credential import (`_validateRelayUrl`), so a plain-HTTP relay
completes SAS and then fails with "Failed to import credentials". Debug
builds accept `http://`. Upstream: block/buzz#4198.
