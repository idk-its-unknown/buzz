import assert from "node:assert/strict";
import test from "node:test";

import { buildUnifiedGroups } from "./unifiedAgentGroups.ts";

function agent(overrides = {}) {
  return {
    name: "Agent",
    pubkey: "a".repeat(64),
    personaId: null,
    displayOnly: false,
    ...overrides,
  };
}

function persona(id, displayName = "Persona") {
  return { id, displayName };
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
    [persona("persona-1")],
    [remoteAgent, localLinked, localCustom],
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
    [persona(pubkey, "Phantom Twin")],
    [staleLinked],
  );

  assert.deepEqual(remote, [staleLinked]);
  assert.deepEqual(ungrouped, []);
  assert.deepEqual(unknown, []);
  assert.equal(groups.length, 1, "the twin definition still renders until cleanup removes it");
  assert.deepEqual(groups[0].agents, [], "but it must not claim the display-only agent");
});
