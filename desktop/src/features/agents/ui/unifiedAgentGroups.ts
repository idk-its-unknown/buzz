import type { AgentPersona, ManagedAgent } from "@/shared/api/types";

type PersonaGroup = { persona: AgentPersona; agents: ManagedAgent[] };

export function buildUnifiedGroups(
  personas: AgentPersona[],
  agents: ManagedAgent[],
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
      remote.push(agent);
    } else if (!agent.personaId) {
      ungrouped.push(agent);
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
    if (!matched.has(id)) unknown.push(...list);
  }

  return { groups, ungrouped, unknown, remote };
}
