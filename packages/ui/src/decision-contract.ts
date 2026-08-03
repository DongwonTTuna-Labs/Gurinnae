export const DECISION_IDS = [
  "approve",
  "request-changes",
  "reject",
  "recuse",
] as const;
export type DecisionId = (typeof DECISION_IDS)[number];

export function decisionCode(id: string): string {
  if (id === "accept-suggestion") return "ACCEPT_SUGGESTION";
  if (id === "reject-suggestion") return "REJECT_SUGGESTION";
  return id === "approve"
    ? "APPROVE"
    : id === "request-changes"
      ? "CHANGES_REQUIRED"
      : id === "recuse"
        ? "RECUSE"
        : "REJECT";
}

export function requiresDecisionReason(id: string): boolean {
  return id !== "approve";
}

export function isAllowedDecisionAction(
  id: string,
  allowedActionIds: readonly string[] | undefined,
): boolean {
  return allowedActionIds === undefined || allowedActionIds.includes(id);
}
