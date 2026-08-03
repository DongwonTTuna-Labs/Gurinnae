export interface SubmitReviewAuthorization {
  capability: "review.editorial" | "review.legal";
  assurance: "ACTIVE_SESSION" | "STEP_UP";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function submitReviewAuthorization(
  operationId: string,
  body: Record<string, unknown> | undefined,
): SubmitReviewAuthorization | undefined {
  if (operationId !== "submitReview") return undefined;
  const criteria = body?.criteria;
  if (
    !isRecord(criteria) ||
    Object.hasOwn(criteria, "namedIndividualOverride")
  ) {
    return { capability: "review.legal", assurance: "STEP_UP" };
  }
  const assurance =
    body?.decision === "reject" ||
    body?.decision === "REJECT" ||
    body?.decision === "changes_required" ||
    body?.decision === "CHANGES_REQUIRED"
      ? "ACTIVE_SESSION"
      : "STEP_UP";
  return {
    capability: "review.editorial",
    assurance,
  };
}
