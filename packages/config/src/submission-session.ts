export const submissionSessionKinds = [
  "RESPONSE_PENDING",
  "RESPONSE_ACTIVE",
  "CORRECTION_DRAFT",
  "SUBSCRIPTION_PENDING",
  "SUBSCRIPTION_MANAGEMENT",
  "RESPONSE_RECEIPT",
  "CORRECTION_RECEIPT",
] as const;

export type SubmissionSessionKind = (typeof submissionSessionKinds)[number];

export type SubmissionSessionPayload = {
  v: 1;
  typ: "submission-session";
  sessionKind: SubmissionSessionKind;
  opaqueSessionToken: string;
  csrfToken: string;
  issuedAt: number;
  absoluteExpiresAt: number;
  csrfRotatedAt: number;
};

export type SubmissionSessionDescriptor = {
  opaqueSessionToken: string;
  sessionKind: SubmissionSessionKind;
  scopeId: string;
  expiresAt: string;
  version: number;
};

export type SubmissionCookieSpec = {
  name: string;
  path: string;
  kinds: readonly SubmissionSessionKind[];
};

const specs: readonly SubmissionCookieSpec[] = [
  {
    name: "gurine_response_receipt_session",
    path: "/respond/receipt",
    kinds: ["RESPONSE_RECEIPT"],
  },
  {
    name: "gurine_correction_receipt_session",
    path: "/correction-request/receipt",
    kinds: ["CORRECTION_RECEIPT"],
  },
  {
    name: "gurine_response_session",
    path: "/respond",
    kinds: ["RESPONSE_PENDING", "RESPONSE_ACTIVE"],
  },
  {
    name: "gurine_correction_session",
    path: "/correction-request",
    kinds: ["CORRECTION_DRAFT"],
  },
  {
    name: "gurine_subscription_session",
    path: "/subscription",
    kinds: ["SUBSCRIPTION_PENDING", "SUBSCRIPTION_MANAGEMENT"],
  },
];

export function submissionCookieForKind(
  kind: SubmissionSessionKind,
): SubmissionCookieSpec {
  const value = specs.find((spec) => spec.kinds.includes(kind));
  if (!value) throw new Error("unsupported submission session kind");
  return value;
}

export function submissionCookiesForPath(
  pathname: string,
): readonly SubmissionCookieSpec[] {
  return specs.filter(
    (spec) => pathname === spec.path || pathname.startsWith(`${spec.path}/`),
  );
}

export function isSubmissionSessionDescriptor(
  value: unknown,
): value is SubmissionSessionDescriptor {
  if (!isRecord(value)) return false;
  return (
    token(value.opaqueSessionToken, 43, 128) &&
    submissionSessionKinds.some((kind) => kind === value.sessionKind) &&
    typeof value.scopeId === "string" &&
    /^[0-9a-f-]{36}$/i.test(value.scopeId) &&
    typeof value.expiresAt === "string" &&
    Number.isFinite(Date.parse(value.expiresAt)) &&
    typeof value.version === "number" &&
    Number.isSafeInteger(value.version) &&
    value.version >= 1
  );
}

export function isSubmissionSessionPayload(
  value: unknown,
): value is SubmissionSessionPayload {
  if (!isRecord(value)) return false;
  return (
    value.v === 1 &&
    value.typ === "submission-session" &&
    submissionSessionKinds.some((kind) => kind === value.sessionKind) &&
    token(value.opaqueSessionToken, 43, 128) &&
    token(value.csrfToken, 43, 128) &&
    integer(value.issuedAt) &&
    integer(value.absoluteExpiresAt) &&
    integer(value.csrfRotatedAt)
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function token(
  value: unknown,
  minimum: number,
  maximum: number,
): value is string {
  return (
    typeof value === "string" &&
    value.length >= minimum &&
    value.length <= maximum &&
    /^[A-Za-z0-9_-]+$/.test(value)
  );
}
function integer(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}
