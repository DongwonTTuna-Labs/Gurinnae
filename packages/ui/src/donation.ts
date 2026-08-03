export const DONATION_INDEPENDENCE_NOTICE =
  "후원은 접근권이 아니며 조사 대상 면제가 아닙니다";

export const DONATION_CONSENT_NOTICE = DONATION_INDEPENDENCE_NOTICE;

export const DONATION_PUBLIC_ACCESS_NOTICE =
  "공개 사실·근거·정정·응답권·기본 구독·합리적 공개 API는 후원 여부와 무관하게 무료입니다.";

export type DonationCadence = "ONE_TIME" | "RECURRING";
export type DonationProvider = "TOSS_PAYMENTS" | "KAKAO_PAY" | "STRIPE";

export type DonationFixtureTier = Readonly<{
  tierId: string;
  amountWholeKrw: number;
}>;

export type DonationOfferViewModel =
  | Readonly<{
      state: "UNAVAILABLE";
      reason: string;
    }>
  | Readonly<{
      state: "READY";
      authority: "TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY";
      offerVersionId: string;
      offerDigest: string;
      currency: "KRW";
      tiers: readonly DonationFixtureTier[];
      cadences: readonly ["ONE_TIME", "RECURRING"];
      providers: readonly ["TOSS_PAYMENTS", "KAKAO_PAY", "STRIPE"];
      productionReadinessEffect: "NONE";
    }>;

export type DonationActionErrorCode =
  | "INVALID_REQUEST"
  | "ORIGIN_DENIED"
  | "OFFER_CHANGED"
  | "RATE_LIMITED"
  | "UNAVAILABLE"
  | "UPSTREAM_INVALID";

export type DonationQueueReceipt = Readonly<{
  requestId: string;
  jobId: string;
  status: "QUEUED";
  receiptDigest: string;
}>;

export type DonationFormSelection = Readonly<{
  tierId: string;
  cadence: DonationCadence;
  provider: DonationProvider;
  consentAccepted: true;
}>;

export type DonationActionState =
  | Readonly<{ state: "IDLE" }>
  | Readonly<{
      state: "ERROR";
      code: DonationActionErrorCode;
      selection?: DonationFormSelection;
    }>
  | Readonly<{ state: "QUEUED"; receipt: DonationQueueReceipt }>;

export type DonationScreenRuntime = Readonly<{
  offer: DonationOfferViewModel;
  action: DonationActionState;
}>;

const ERROR_CODES = new Set<DonationActionErrorCode>([
  "INVALID_REQUEST",
  "ORIGIN_DENIED",
  "OFFER_CHANGED",
  "RATE_LIMITED",
  "UNAVAILABLE",
  "UPSTREAM_INVALID",
]);

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const SHA256 = /^[0-9a-f]{64}$/u;

export function donationActionState(value: unknown): DonationActionState {
  if (value === undefined || value === null) return { state: "IDLE" };
  if (!isRecord(value) || !isRecord(value.donationAction)) {
    return { state: "ERROR", code: "UPSTREAM_INVALID" };
  }
  const action = value.donationAction;
  if (action.state === "ERROR" && isDonationActionErrorCode(action.code)) {
    const selection = donationFormSelection(value.donationSelection);
    return selection
      ? { state: "ERROR", code: action.code, selection }
      : { state: "ERROR", code: action.code };
  }
  if (
    action.state !== "QUEUED" ||
    !isRecord(action.receipt) ||
    action.receipt.status !== "QUEUED" ||
    !isUuid(action.receipt.requestId) ||
    !isUuid(action.receipt.jobId) ||
    !isSha256(action.receipt.receiptDigest)
  ) {
    return { state: "ERROR", code: "UPSTREAM_INVALID" };
  }
  return {
    state: "QUEUED",
    receipt: {
      requestId: action.receipt.requestId,
      jobId: action.receipt.jobId,
      status: "QUEUED",
      receiptDigest: action.receipt.receiptDigest,
    },
  };
}

export function donationFormSelection(
  value: unknown,
): DonationFormSelection | undefined {
  if (
    !isRecord(value) ||
    !hasExactKeys(value, [
      "tierId",
      "cadence",
      "provider",
      "consentAccepted",
    ]) ||
    !isUuid(value.tierId) ||
    !isDonationCadence(value.cadence) ||
    !isDonationProvider(value.provider) ||
    value.consentAccepted !== true
  ) {
    return undefined;
  }
  return {
    tierId: value.tierId,
    cadence: value.cadence,
    provider: value.provider,
    consentAccepted: true,
  };
}

export function donationActionErrorMessage(
  code: DonationActionErrorCode,
): string {
  switch (code) {
    case "INVALID_REQUEST":
      return "후원 요청 입력을 다시 확인해 주세요.";
    case "ORIGIN_DENIED":
      return "요청 출처를 확인할 수 없어 접수하지 않았습니다.";
    case "OFFER_CHANGED":
      return "후원 금액 구성이 변경되었습니다. 화면을 새로고침해 주세요.";
    case "RATE_LIMITED":
      return "요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.";
    case "UNAVAILABLE":
      return "테스트 후원 접수 경로를 현재 사용할 수 없습니다.";
    case "UPSTREAM_INVALID":
      return "접수 영수증을 검증할 수 없어 완료로 표시하지 않습니다.";
  }
}

export function donationCadenceLabel(cadence: DonationCadence): string {
  return cadence === "ONE_TIME" ? "일회 후원" : "정기 후원";
}

export function donationProviderLabel(provider: DonationProvider): string {
  switch (provider) {
    case "TOSS_PAYMENTS":
      return "토스페이먼츠";
    case "KAKAO_PAY":
      return "카카오페이";
    case "STRIPE":
      return "Stripe";
  }
}

export function donationReceiptStatusLabel(status: "QUEUED"): string {
  return status === "QUEUED" ? "접수 대기" : status;
}

export function donationAmountLabel(amountWholeKrw: number): string {
  return new Intl.NumberFormat("ko-KR", {
    style: "currency",
    currency: "KRW",
    maximumFractionDigits: 0,
  }).format(amountWholeKrw);
}

function isDonationActionErrorCode(
  value: unknown,
): value is DonationActionErrorCode {
  return (
    typeof value === "string" &&
    ERROR_CODES.has(value as DonationActionErrorCode)
  );
}

function isDonationCadence(value: unknown): value is DonationCadence {
  return value === "ONE_TIME" || value === "RECURRING";
}

function isDonationProvider(value: unknown): value is DonationProvider {
  return (
    value === "TOSS_PAYMENTS" || value === "KAKAO_PAY" || value === "STRIPE"
  );
}

function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID.test(value);
}

function isSha256(value: unknown): value is string {
  return typeof value === "string" && SHA256.test(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(
  value: Record<string, unknown>,
  expected: readonly string[],
): boolean {
  const keys = Object.keys(value);
  return (
    keys.length === expected.length &&
    keys.every((key) => expected.includes(key))
  );
}
