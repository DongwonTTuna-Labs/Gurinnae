export const SCREEN_ARCHETYPES = [
  "EVIDENCE_LANDING",
  "SEARCH_INDEX",
  "ENTITY_DETAIL",
  "POLICY",
  "GUIDED_FORM",
  "QUEUE",
  "WORKSPACE",
  "DECISION_REVIEW",
  "OPERATIONS",
  "AUTH_SYSTEM",
] as const;

export type ScreenArchetype = (typeof SCREEN_ARCHETYPES)[number];

export const ARCHETYPE_ASSEMBLY_IDS = [
  "evidence-landing",
  "record",
  "policy",
  "guided-form",
  "queue",
  "workspace",
  "decision-review",
  "operations",
] as const;

export type ArchetypeAssemblyId = (typeof ARCHETYPE_ASSEMBLY_IDS)[number];

export const ARCHETYPE_ASSEMBLIES = {
  EVIDENCE_LANDING: "evidence-landing",
  SEARCH_INDEX: "record",
  ENTITY_DETAIL: "record",
  POLICY: "policy",
  GUIDED_FORM: "guided-form",
  QUEUE: "queue",
  WORKSPACE: "workspace",
  DECISION_REVIEW: "decision-review",
  OPERATIONS: "operations",
  AUTH_SYSTEM: "guided-form",
} as const satisfies Record<ScreenArchetype, ArchetypeAssemblyId>;

const SCREEN_ARCHETYPE_SET: ReadonlySet<string> = new Set(SCREEN_ARCHETYPES);

export function isScreenArchetype(value: string): value is ScreenArchetype {
  return SCREEN_ARCHETYPE_SET.has(value);
}

export function archetypeAssemblyFor(archetype: string): ArchetypeAssemblyId {
  if (!isScreenArchetype(archetype)) {
    throw new Error(`unsupported screen archetype: ${archetype}`);
  }
  return ARCHETYPE_ASSEMBLIES[archetype];
}
