import assert from "node:assert/strict";
import test from "node:test";

import { buildUnifiedGroups } from "./unifiedAgentGroups.ts";

const NONE_ARCHIVED = () => false;

function agent(overrides = {}) {
  return {
    name: "Agent",
    pubkey: "a".repeat(64),
    personaId: null,
    displayOnly: false,
    status: "stopped",
    ...overrides,
  };
}

function persona(overrides = {}) {
  return { id: "persona-1", displayName: "Persona", ...overrides };
}

test("display-only agents take the remote group, never persona groups or the custom bucket", () => {
  const remoteAgent = agent({
    name: "Fleet CFO",
    pubkey: "b".repeat(64),
    displayOnly: true,
  });
  const localLinked = agent({
    name: "Honey",
    pubkey: "c".repeat(64),
    personaId: "persona-1",
  });
  const localCustom = agent({ name: "Solo", pubkey: "d".repeat(64) });

  const { groups, ungrouped, unknown, remote } = buildUnifiedGroups(
    [persona()],
    [remoteAgent, localLinked, localCustom],
    NONE_ARCHIVED,
  );

  assert.deepEqual(remote, [remoteAgent]);
  assert.deepEqual(ungrouped, [localCustom]);
  assert.deepEqual(unknown, []);
  assert.equal(groups.length, 1);
  assert.deepEqual(groups[0].agents, [localLinked]);
});

test("a stale persona link on a display-only record is a twin artifact — remote group still wins", () => {
  // Pre-cleanup shape: the record still carries personaId = own pubkey and the
  // twin definition still exists. The agent must NOT appear under the twin's
  // persona group (that card's lifecycle actions target nothing manageable).
  const pubkey = "e".repeat(64);
  const staleLinked = agent({
    name: "Fleet Ops",
    pubkey,
    personaId: pubkey,
    displayOnly: true,
  });

  const { groups, ungrouped, unknown, remote } = buildUnifiedGroups(
    [persona({ id: pubkey, displayName: "Phantom Twin" })],
    [staleLinked],
    NONE_ARCHIVED,
  );

  assert.deepEqual(remote, [staleLinked]);
  assert.deepEqual(ungrouped, []);
  assert.deepEqual(unknown, []);
  assert.equal(groups.length, 1, "the twin definition still renders until cleanup removes it");
  assert.deepEqual(groups[0].agents, [], "but it must not claim the display-only agent");
});

test("display-only agents are NOT archive-filtered — a fleet mirror stays visible regardless of local archive state", () => {
  // Remote mirrors reflect the fleet on the remote harness, not local archive
  // state, and have no persona-group fallback to keep them reachable — so the
  // remote group deliberately ignores isArchived (unlike the local buckets).
  const archived = agent({ pubkey: "a".repeat(64), displayOnly: true });
  const live = agent({ pubkey: "b".repeat(64), displayOnly: true });
  const isArchived = (pubkey) => pubkey === archived.pubkey;

  const { remote } = buildUnifiedGroups([], [archived, live], isArchived);

  assert.deepEqual(
    remote.map((agent) => agent.pubkey).sort(),
    [archived.pubkey, live.pubkey].sort(),
  );
});

test("archived standalone custom agents are omitted while live peers remain", () => {
  const archived = agent({ pubkey: "a".repeat(64), personaId: null });
  const live = agent({ pubkey: "b".repeat(64), personaId: null });
  const isArchived = (pubkey) => pubkey === archived.pubkey;

  const { ungrouped } = buildUnifiedGroups([], [archived, live], isArchived);

  assert.deepEqual(
    ungrouped.map((agent) => agent.pubkey),
    [live.pubkey],
  );
});

test("archived unknown-persona agents are omitted while live peers remain", () => {
  const archived = agent({ pubkey: "a".repeat(64), personaId: "orphan" });
  const live = agent({ pubkey: "b".repeat(64), personaId: "orphan" });
  const isArchived = (pubkey) => pubkey === archived.pubkey;

  // No persona matches "orphan", so both land in the unknown bucket.
  const { unknown } = buildUnifiedGroups([], [archived, live], isArchived);

  assert.deepEqual(
    unknown.map((agent) => agent.pubkey),
    [live.pubkey],
  );
});

test("matched persona groups keep their full instance list including archived", () => {
  const archived = agent({ pubkey: "a".repeat(64), personaId: "persona-1" });
  const live = agent({ pubkey: "b".repeat(64), personaId: "persona-1" });
  const isArchived = (pubkey) => pubkey === archived.pubkey;

  // The card resolves its own target via pickProfileAgent; the group keeps the
  // archived record so an all-archived persona still forms a card in
  // persona-only mode rather than vanishing from the library.
  const { groups } = buildUnifiedGroups(
    [persona()],
    [archived, live],
    isArchived,
  );

  assert.equal(groups.length, 1);
  assert.deepEqual(
    groups[0].agents.map((agent) => agent.pubkey).sort(),
    [archived.pubkey, live.pubkey].sort(),
  );
});

test("a fail-open predicate keeps every standalone agent discoverable", () => {
  const first = agent({ pubkey: "a".repeat(64), personaId: null });
  const second = agent({ pubkey: "b".repeat(64), personaId: null });

  const { ungrouped } = buildUnifiedGroups([], [first, second], NONE_ARCHIVED);

  assert.equal(ungrouped.length, 2);
});
