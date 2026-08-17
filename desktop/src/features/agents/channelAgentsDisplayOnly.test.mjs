/**
 * Unit tests for display-only agent handling — the fix for the
 * mention-interception bug (#4833) and the display-only remote-agent
 * feature (#4834).
 *
 * These tests import and exercise the ACTUAL exported functions.
 *
 * shouldStartOnAttach properties under test:
 *   (a) displayOnly agent, any backend, any status  → never starts
 *   (b) ensureRunning=false                          → never starts
 *   (c) provider backend, not deployed               → starts (deploy)
 *   (d) provider backend, deployed                   → no start
 *   (e) local backend, stopped                       → starts
 *   (f) local backend, running or deployed           → no start
 *
 * isDisplayOnlyAgent: mirrors the record flag verbatim.
 */

import assert from "node:assert/strict";
import test from "node:test";

import { shouldStartOnAttach } from "./channelAgents.ts";
import { isDisplayOnlyAgent } from "../messages/ui/useMentionSendFlow.helpers.ts";

const LOCAL_BACKEND = { type: "local" };
const PROVIDER_BACKEND = { type: "provider", id: "buzz-backend-x", config: {} };

function agent(overrides = {}) {
  return {
    backend: LOCAL_BACKEND,
    displayOnly: false,
    status: "stopped",
    ...overrides,
  };
}

test("displayOnly agent never starts on attach, regardless of backend or status", () => {
  for (const backend of [LOCAL_BACKEND, PROVIDER_BACKEND]) {
    for (const status of ["stopped", "running", "deployed", "not_deployed"]) {
      assert.equal(
        shouldStartOnAttach(agent({ backend, status, displayOnly: true }), true),
        false,
        `displayOnly must suppress start (backend=${backend.type}, status=${status})`,
      );
    }
  }
});

test("ensureRunning=false never starts", () => {
  assert.equal(shouldStartOnAttach(agent({ status: "stopped" }), false), false);
  assert.equal(
    shouldStartOnAttach(
      agent({ backend: PROVIDER_BACKEND, status: "not_deployed" }),
      false,
    ),
    false,
  );
});

test("provider backend starts only when not deployed", () => {
  assert.equal(
    shouldStartOnAttach(
      agent({ backend: PROVIDER_BACKEND, status: "not_deployed" }),
      true,
    ),
    true,
  );
  assert.equal(
    shouldStartOnAttach(
      agent({ backend: PROVIDER_BACKEND, status: "deployed" }),
      true,
    ),
    false,
  );
});

test("local backend starts only when neither running nor deployed", () => {
  assert.equal(shouldStartOnAttach(agent({ status: "stopped" }), true), true);
  assert.equal(shouldStartOnAttach(agent({ status: "running" }), true), false);
  // "deployed" is what build_managed_agent_summary forces for display_only
  // records — even without the explicit flag check, that status must read as
  // not-startable.
  assert.equal(shouldStartOnAttach(agent({ status: "deployed" }), true), false);
});

test("isDisplayOnlyAgent mirrors the flag", () => {
  assert.equal(isDisplayOnlyAgent(agent({ displayOnly: true })), true);
  assert.equal(isDisplayOnlyAgent(agent({ displayOnly: false })), false);
});
