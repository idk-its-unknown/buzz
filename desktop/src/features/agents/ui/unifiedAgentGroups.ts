import type { AgentPersona, ManagedAgent } from "@/shared/api/types";

type PersonaGroup = { persona: AgentPersona; agents: ManagedAgent[] };

/**
 * Group managed agents under their personas for the Agents library.
 *
 * Archived instances are dropped from the standalone `ungrouped` (custom
 * agents) and `unknown` buckets so a relay-archived identity never shows as a
 * clickable library card of its own. Matched persona groups keep their full
 * instance list — the persona card resolves its own target through
 * `pickProfileAgent`, which applies the same `isArchived` filter and falls back
 * to persona-only mode when every instance is archived. `isArchived` is
 * fail-open (returns `false` while the relay archive snapshot loads).
 */
export function buildUnifiedGroups(
  personas: AgentPersona[],
  agents: ManagedAgent[],
  isArchived: (pubkey: string) => boolean,
) {
  const byPersonaId = new Map<string, ManagedAgent[]>();
  const ungrouped: ManagedAgent[] = [];
  const remote: ManagedAgent[] = [];

  for (const agent of agents) {
    if (agent.displayOnly) {
      // Display-only records mirror agents managed on a remote harness. They
      // are definition-less by design (the phantom-twin backfill gate keeps
      // them that way), and any persona link a stale record still carries is
      // a twin artifact — so they take their own group unconditionally,
      // before persona matching.
      //
      // NOT archive-filtered (unlike the local buckets below): a remote agent's
      // presence on the hub reflects the fleet on the remote harness, not local
      // archive state. Upstream's archive-awareness applies to locally-owned
      // agents; a fleet mirror hidden by a local archive would vanish with no
      // persona-group fallback to keep it reachable. This preserves the fork's
      // pre-merge behavior.
      remote.push(agent);
    } else if (!agent.personaId) {
      if (!isArchived(agent.pubkey)) ungrouped.push(agent);
    } else {
      const list = byPersonaId.get(agent.personaId) ?? [];
      list.push(agent);
      byPersonaId.set(agent.personaId, list);
    }
  }

  const matched = new Set<string>();
  const groups: PersonaGroup[] = personas.map((persona) => {
    matched.add(persona.id);
    return { persona, agents: byPersonaId.get(persona.id) ?? [] };
  });

  const unknown: ManagedAgent[] = [];
  for (const [id, list] of byPersonaId) {
    if (!matched.has(id)) {
      unknown.push(...list.filter((agent) => !isArchived(agent.pubkey)));
    }
  }

  return { groups, ungrouped, unknown, remote };
}
