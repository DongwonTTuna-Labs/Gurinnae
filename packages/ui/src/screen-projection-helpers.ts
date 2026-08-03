import type { ScreenViewModel, SemanticRegion } from "./index";
import type {
  ScreenProjection,
  ScreenSectionProjection,
} from "./screen-projection";

export function normalizeRegion(region: string): SemanticRegion {
  const map: Record<string, SemanticRegion> = {
    object: "identity",
    answer: "priority",
    next_action: "next-action",
    "next-action": "next-action",
    unknown: "unknowns",
    state: "state",
    evidence: "evidence",
    review: "review",
    triage: "triage",
    approval: "approval",
    analysis: "analysis",
    commercial: "commercial",
    identity: "identity",
    priority: "priority",
  };
  return map[region] ?? "state";
}

export function sectionProjection(
  projection: ScreenProjection,
  sectionId: string,
): ScreenSectionProjection {
  const section = projection.sections[sectionId];
  if (!section)
    throw new Error(
      `section projection missing: ${projection.screenId}.${sectionId}`,
    );
  return section;
}

export function valueAtPath(value: unknown, path: string): unknown {
  const normalized = path
    .replace(/^\$projection\.?/u, "projection.")
    .replace(/^\$\.?/u, "")
    .replace(/^\.?/u, "");
  if (normalized.length === 0) return value;
  return normalized.split(".").reduce<unknown>((current, key) => {
    if (current && typeof current === "object" && !Array.isArray(current)) {
      return (current as Record<string, unknown>)[key];
    }
    return undefined;
  }, value);
}

export function restoreAction(screen: ScreenViewModel): string | null {
  const preferredId = screen.id === "RSP-005" ? "change-answer" : null;
  const value = preferredId
    ? screen.actions.find((action) => action.id === preferredId)
    : screen.actions[0];
  return value?.id ?? screen.actions[0]?.id ?? null;
}
