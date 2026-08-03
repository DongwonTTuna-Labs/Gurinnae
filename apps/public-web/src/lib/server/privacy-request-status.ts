export type PrivacyRequestStatusPresentation = Readonly<{
  requestType: "ACCESS" | "CORRECTION" | "DELETION" | "RESTRICTION";
  state: "RECEIVED" | "REVIEW" | "APPROVED" | "REJECTED" | "COMPLETED";
  identityState: "PENDING_VERIFICATION" | "VERIFIED";
  identityVerifiedAt: string | null;
  dueAt: string | null;
  updatedAt: string;
  nextActionCode:
    | "VERIFY_IDENTITY"
    | "AWAIT_REVIEW"
    | "AWAIT_DECISION"
    | "AWAIT_EXECUTION"
    | "REVIEW_REFUSAL_NOTICE"
    | "COMPLETE";
  asOf: string;
}>;

const responseKeys = [
  "asOf",
  "decisionReasonCode",
  "decisionReceiptId",
  "decisionReceiptSha256",
  "links",
  "nextActionCodes",
  "noticeReceiptIds",
  "noticeReceiptSha256s",
  "operationId",
  "refusalNoticeReceiptId",
  "refusalNoticeReceiptSha256",
  "request",
] as const;

const requestKeys = [
  "createdAt",
  "dueAt",
  "identityState",
  "identityVerifiedAt",
  "jurisdiction",
  "privacyRequestId",
  "requestType",
  "scopeDigest",
  "state",
  "updatedAt",
] as const;

const requestTypes = [
  "ACCESS",
  "CORRECTION",
  "DELETION",
  "RESTRICTION",
] as const;
const states = [
  "RECEIVED",
  "REVIEW",
  "APPROVED",
  "REJECTED",
  "COMPLETED",
] as const;
const identityStates = ["PENDING_VERIFICATION", "VERIFIED"] as const;
const nextActions = [
  "VERIFY_IDENTITY",
  "AWAIT_REVIEW",
  "AWAIT_DECISION",
  "AWAIT_EXECUTION",
  "REVIEW_REFUSAL_NOTICE",
  "COMPLETE",
] as const;

/**
 * Validate the complete server response before copying the small status view
 * model across the browser boundary. Receipt identities and digests are
 * checked for consistency but deliberately omitted from the presentation.
 */
export function parsePrivacyRequestStatus(
  value: unknown,
): PrivacyRequestStatusPresentation | undefined {
  const response = exactRecord(value, responseKeys);
  const request = exactRecord(response?.request, requestKeys);
  if (!response || !request || response.operationId !== "getPrivacyRequest")
    return;
  const requestType = closedValue(request.requestType, requestTypes);
  const state = closedValue(request.state, states);
  const identityState = closedValue(request.identityState, identityStates);
  const identityVerifiedAt = nullableTimestamp(request.identityVerifiedAt);
  const dueAt = nullableTimestamp(request.dueAt);
  const createdAt = timestamp(request.createdAt);
  const updatedAt = timestamp(request.updatedAt);
  const asOf = timestamp(response.asOf);
  const action = oneClosedValue(response.nextActionCodes, nextActions);
  if (
    !requestType ||
    !state ||
    !identityState ||
    identityVerifiedAt === undefined ||
    dueAt === undefined ||
    !createdAt ||
    !updatedAt ||
    !asOf ||
    !action ||
    !uuid(request.privacyRequestId) ||
    !boundedText(request.jurisdiction, 2, 64) ||
    !sha256(request.scopeDigest) ||
    !nullableBoundedText(response.decisionReasonCode, 1, 100) ||
    !receiptPair(response.decisionReceiptId, response.decisionReceiptSha256) ||
    !receiptPair(
      response.refusalNoticeReceiptId,
      response.refusalNoticeReceiptSha256,
    ) ||
    !receiptArrays(response.noticeReceiptIds, response.noticeReceiptSha256s) ||
    !links(response.links) ||
    !identityTimeline(identityState, identityVerifiedAt, dueAt) ||
    !statusAction(
      state,
      identityState,
      action,
      response.decisionReceiptId,
      response.refusalNoticeReceiptId,
    )
  )
    return;
  return {
    requestType,
    state,
    identityState,
    identityVerifiedAt,
    dueAt,
    updatedAt,
    nextActionCode: action,
    asOf,
  };
}

function identityTimeline(
  state: (typeof identityStates)[number],
  verifiedAt: string | null,
  dueAt: string | null,
): boolean {
  if (state === "PENDING_VERIFICATION")
    return verifiedAt === null && dueAt === null;
  return (
    verifiedAt !== null &&
    dueAt !== null &&
    Date.parse(dueAt) > Date.parse(verifiedAt)
  );
}

function statusAction(
  state: (typeof states)[number],
  identityState: (typeof identityStates)[number],
  action: (typeof nextActions)[number],
  decisionReceiptId: unknown,
  refusalNoticeReceiptId: unknown,
): boolean {
  if (identityState === "PENDING_VERIFICATION")
    return state === "RECEIVED" && action === "VERIFY_IDENTITY";
  if (state === "RECEIVED") return action === "AWAIT_REVIEW";
  if (state === "REVIEW") return action === "AWAIT_DECISION";
  if (state === "APPROVED") return action === "AWAIT_EXECUTION";
  if (state === "COMPLETED")
    return action === "COMPLETE" && decisionReceiptId !== null;
  return (
    action === "REVIEW_REFUSAL_NOTICE" &&
    decisionReceiptId !== null &&
    refusalNoticeReceiptId !== null
  );
}

function receiptPair(id: unknown, digest: unknown): boolean {
  return (id === null && digest === null) || (uuid(id) && sha256(digest));
}

function receiptArrays(ids: unknown, digests: unknown): boolean {
  return (
    Array.isArray(ids) &&
    Array.isArray(digests) &&
    ids.length <= 100 &&
    ids.length === digests.length &&
    ids.every(uuid) &&
    digests.every(sha256)
  );
}

function links(value: unknown): boolean {
  if (!Array.isArray(value) || value.length > 16) return false;
  return value.every((item) => {
    const link = record(item);
    if (!link) return false;
    const keys = Object.keys(link).sort();
    const expected =
      link.label === undefined ? ["href", "rel"] : ["href", "label", "rel"];
    return (
      keys.length === expected.length &&
      expected.every((key, index) => keys[index] === key) &&
      boundedText(link.href, 1, 4096) &&
      boundedText(link.rel, 1, 100) &&
      (link.label === undefined || boundedText(link.label, 1, 500))
    );
  });
}

function oneClosedValue<const T extends readonly string[]>(
  value: unknown,
  allowed: T,
): T[number] | undefined {
  if (!Array.isArray(value) || value.length !== 1) return;
  return closedValue(value[0], allowed);
}

function closedValue<const T extends readonly string[]>(
  value: unknown,
  allowed: T,
): T[number] | undefined {
  return typeof value === "string" && allowed.includes(value)
    ? (value as T[number])
    : undefined;
}

function nullableTimestamp(value: unknown): string | null | undefined {
  if (value === null) return null;
  return timestamp(value) ?? undefined;
}

function nullableBoundedText(
  value: unknown,
  minimum: number,
  maximum: number,
): boolean {
  return value === null || boundedText(value, minimum, maximum);
}

function boundedText(
  value: unknown,
  minimum: number,
  maximum: number,
): value is string {
  return (
    typeof value === "string" &&
    value.length >= minimum &&
    value.length <= maximum
  );
}

function timestamp(value: unknown): string | undefined {
  return typeof value === "string" && Number.isFinite(Date.parse(value))
    ? value
    : undefined;
}

function uuid(value: unknown): value is string {
  return (
    typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(
      value,
    )
  );
}

function sha256(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f]{64}$/u.test(value);
}

function exactRecord<const TKeys extends readonly string[]>(
  value: unknown,
  keys: TKeys,
): Record<TKeys[number], unknown> | undefined {
  const item = record(value);
  if (!item) return;
  const actual = Object.keys(item).sort();
  if (
    actual.length !== keys.length ||
    keys.some((key, index) => actual[index] !== key)
  )
    return;
  return item as Record<TKeys[number], unknown>;
}

function record(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}
