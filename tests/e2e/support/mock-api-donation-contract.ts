import { sha256, sortJson } from "./mock-api-state";

export const DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN =
  "TEST_ONLY_PAYMENT_AUTHORIZATION_TOKEN_DO_NOT_USE";
const DONATION_NOTICE = "후원은 접근권이 아니며 조사 대상 면제가 아닙니다";
const OFFER_VERSION_ID = "11111111-1111-4111-8111-111111111111";
const TIER_ID = "22222222-2222-4222-8222-222222222222";
const JOB_ID = "44444444-4444-4444-8444-444444444444";
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;

const offerBase = {
  schemaVersion: "donation-offer-fixture.v1",
  authority: "TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY",
  offerVersionId: OFFER_VERSION_ID,
  currency: "KRW",
  tiers: [{ tierId: TIER_ID, amountWholeKrw: 10_000 }],
  cadences: ["ONE_TIME", "RECURRING"],
  providers: ["TOSS_PAYMENTS", "KAKAO_PAY", "STRIPE"],
  productionReadinessEffect: "NONE",
};
const offerDigest = canonicalSha256({
  fixtureAuthority: "TEST_FIXTURE",
  offer: offerBase,
});
export const DONATION_FIXTURE_OFFER = Object.freeze({
  ...offerBase,
  offerDigest,
});

export type DonationQueueRequest = Readonly<{
  schemaVersion: "donation-intent-request.v1";
  requestId: string;
  offerVersionId: string;
  offerDigest: string;
  tierId: string;
  cadence: "ONE_TIME" | "RECURRING";
  provider: "TOSS_PAYMENTS" | "KAKAO_PAY" | "STRIPE";
  consentReceiptDigest: string;
  paymentAuthorizationToken: string;
}>;
export type PrivateDonationOperationId =
  | "private.GetDonationFixtureOffer"
  | "private.QueueDonationIntent";
export type PrivateDonationContractValidation = Readonly<{
  operationId: PrivateDonationOperationId;
  ok: boolean;
  message?: string;
}>;

export function resolvePrivateDonationOperation(
  request: Request,
  url: URL,
): PrivateDonationOperationId | undefined {
  if (
    request.method === "GET" &&
    url.pathname === "/internal/v1/donation-offers"
  ) {
    return "private.GetDonationFixtureOffer";
  }
  if (
    request.method === "POST" &&
    url.pathname === "/internal/v1/donation-intents"
  ) {
    return "private.QueueDonationIntent";
  }
  return undefined;
}

export async function parseDonationQueueRequest(
  request: Request,
): Promise<DonationQueueRequest | undefined> {
  if (
    new URL(request.url).searchParams.size !== 0 ||
    !request.headers.get("content-type")?.startsWith("application/json")
  ) {
    return undefined;
  }
  const value: unknown = await request
    .clone()
    .json()
    .catch(() => undefined);
  if (!isRecord(value) || !exactKeys(value, QUEUE_REQUEST_KEYS)) {
    return undefined;
  }
  const requestId = value.requestId;
  const cadence = value.cadence;
  const provider = value.provider;
  if (
    value.schemaVersion !== "donation-intent-request.v1" ||
    !isUuid(requestId) ||
    value.offerVersionId !== OFFER_VERSION_ID ||
    value.offerDigest !== offerDigest ||
    value.tierId !== TIER_ID ||
    (cadence !== "ONE_TIME" && cadence !== "RECURRING") ||
    !isDonationProvider(provider) ||
    value.paymentAuthorizationToken !==
      DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN ||
    request.headers.get("idempotency-key") !== requestId
  ) {
    return undefined;
  }
  const expectedConsent = consentReceiptDigest({
    requestId,
    cadence,
    provider,
  });
  if (value.consentReceiptDigest !== expectedConsent) return undefined;
  return {
    schemaVersion: "donation-intent-request.v1",
    requestId,
    offerVersionId: OFFER_VERSION_ID,
    offerDigest,
    tierId: TIER_ID,
    cadence,
    provider,
    consentReceiptDigest: expectedConsent,
    paymentAuthorizationToken: DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN,
  };
}

export function donationQueuedReceipt(input: DonationQueueRequest) {
  const receiptBase = {
    schemaVersion: "donation-intent-queued.v1",
    requestId: input.requestId,
    jobId: JOB_ID,
    status: "QUEUED",
  } as const;
  return {
    ...receiptBase,
    receiptDigest: canonicalSha256({
      fixtureAuthority: "TEST_FIXTURE",
      jobId: receiptBase.jobId,
      requestId: receiptBase.requestId,
      status: receiptBase.status,
    }),
  };
}

export async function validatePrivateDonationMockContract(
  request: Request,
  response: Response,
): Promise<PrivateDonationContractValidation | undefined> {
  const url = new URL(request.url);
  const operationId = resolvePrivateDonationOperation(request, url);
  if (!operationId) return undefined;
  const contentType = response.headers
    .get("content-type")
    ?.split(";", 1)[0]
    ?.trim()
    .toLowerCase();
  if (
    contentType !== "application/json" &&
    contentType?.endsWith("+json") !== true
  ) {
    return { operationId, ok: false, message: "JSON content-type is required" };
  }
  const value: unknown = await response
    .clone()
    .json()
    .catch(() => undefined);
  if (response.status >= 400) {
    return validProblem(value, response.status)
      ? { operationId, ok: true }
      : { operationId, ok: false, message: "invalid private problem body" };
  }
  if (operationId === "private.GetDonationFixtureOffer") {
    return response.status === 200 &&
      canonicalJson(value) === canonicalJson(DONATION_FIXTURE_OFFER)
      ? { operationId, ok: true }
      : { operationId, ok: false, message: "invalid closed fixture offer" };
  }
  const input = await parseDonationQueueRequest(request);
  return response.status === 202 &&
    input &&
    canonicalJson(value) === canonicalJson(donationQueuedReceipt(input))
    ? { operationId, ok: true }
    : { operationId, ok: false, message: "invalid queued receipt binding" };
}

function consentReceiptDigest(input: {
  requestId: string;
  cadence: DonationQueueRequest["cadence"];
  provider: DonationQueueRequest["provider"];
}): string {
  return sha256(
    [
      "gurine-donation-consent-receipt.v1",
      input.requestId,
      OFFER_VERSION_ID,
      offerDigest,
      TIER_ID,
      input.cadence,
      input.provider,
      "DONATION-INDEPENDENCE-NOTICE-v1",
      DONATION_NOTICE,
      "ACCEPTED",
    ].join("\n"),
  );
}

function validProblem(value: unknown, status: number): boolean {
  return (
    isRecord(value) &&
    exactKeys(value, PROBLEM_KEYS) &&
    value.type === "about:blank" &&
    typeof value.title === "string" &&
    value.status === status &&
    isUuid(value.requestId) &&
    [
      "SERVICE_ASSERTION_REQUIRED",
      "DEPENDENCY_UNAVAILABLE",
      "INVALID_PARAMETER",
    ].includes(String(value.code))
  );
}

const QUEUE_REQUEST_KEYS = [
  "schemaVersion",
  "requestId",
  "offerVersionId",
  "offerDigest",
  "tierId",
  "cadence",
  "provider",
  "consentReceiptDigest",
  "paymentAuthorizationToken",
] as const;
const PROBLEM_KEYS = ["type", "title", "status", "requestId", "code"] as const;

function exactKeys(
  value: Record<string, unknown>,
  expected: readonly string[],
): boolean {
  const keys = Object.keys(value);
  return (
    keys.length === expected.length &&
    keys.every((key) => expected.includes(key))
  );
}

function canonicalJson(value: unknown): string {
  return JSON.stringify(sortJson(value));
}

function canonicalSha256(value: unknown): string {
  return sha256(canonicalJson(value));
}

function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

function isDonationProvider(
  value: unknown,
): value is DonationQueueRequest["provider"] {
  return (
    value === "TOSS_PAYMENTS" || value === "KAKAO_PAY" || value === "STRIPE"
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
