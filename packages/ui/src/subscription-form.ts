import type { ScreenField, ScreenRuntime, ScreenViewModel } from "./index";

export const PUBLIC_SUBSCRIPTION_ACTION_ID = "request-verification";

const OPERATION_ID = "createSubscription";
const FIELD_NAMES = [
  "email",
  "scopeType",
  "scopeRef",
  "query",
  "frequency",
  "locale",
  "consent",
  "abuseProof",
] as const;

export const SUBSCRIPTION_SCOPE_LABELS = {
  GLOBAL: "전체 공개 기록",
  QUERY: "검색 조건",
  CASE: "사건",
  AGENCY: "기관",
  SUPPLIER: "업체",
  REGION: "지역",
  CORRECTIONS: "정정",
} as const;

export const SUBSCRIPTION_FREQUENCY_LABELS = {
  IMMEDIATE: "즉시",
  DAILY: "일간",
  WEEKLY: "주간",
} as const;

export type SubscriptionScopeType = keyof typeof SUBSCRIPTION_SCOPE_LABELS;
export type SubscriptionFrequency = keyof typeof SUBSCRIPTION_FREQUENCY_LABELS;

export type PublicSubscriptionFormModel = Readonly<{
  actionId: typeof PUBLIC_SUBSCRIPTION_ACTION_ID;
  actionLabel: string;
  formAction: string;
  idempotencyKey: string;
  email: ScreenField;
  scopeType: ScreenField;
  scopeRef: ScreenField;
  query: ScreenField;
  frequency: ScreenField;
  locale: ScreenField;
  consent: ScreenField;
  abuseProof: ScreenField;
  fixedFields: readonly ScreenField[];
  fixedScopeType?: SubscriptionScopeType;
}>;

export type PublicSubscriptionFormResult =
  | Readonly<{ ready: true; model: PublicSubscriptionFormModel }>
  | Readonly<{ ready: false; reason: string }>;

export function publicSubscriptionForm(
  screen: ScreenViewModel,
  runtime: ScreenRuntime,
): PublicSubscriptionFormResult {
  if (screen.id !== "PUB-029")
    return blocked("PUB-029 화면 계약에서만 구독 폼을 만들 수 있습니다.");

  const action = screen.actions.find(
    (candidate) => candidate.id === PUBLIC_SUBSCRIPTION_ACTION_ID,
  );
  if (!action || action.operation_id !== OPERATION_ID)
    return blocked("구독 생성 동작 계약을 확인할 수 없습니다.");
  const idempotencyKey =
    runtime.idempotencyKeys?.[PUBLIC_SUBSCRIPTION_ACTION_ID];
  if (
    !idempotencyKey ||
    idempotencyKey.length < 8 ||
    idempotencyKey.length > 200 ||
    !/^[\x20-\x7e]+$/.test(idempotencyKey)
  )
    return blocked("구독 제출 멱등성 계약을 확인할 수 없습니다.");

  const fields = runtime.forms[PUBLIC_SUBSCRIPTION_ACTION_ID];
  if (!fields) return blocked("구독 입력 계약을 확인할 수 없습니다.");
  const duplicate = duplicateName(fields);
  if (duplicate)
    return blocked(`구독 입력 계약에 ${duplicate} 필드가 중복됩니다.`);

  const unknown = fields.find(
    (field) =>
      !FIELD_NAMES.includes(field.name as (typeof FIELD_NAMES)[number]),
  );
  if (unknown)
    return blocked(`지원하지 않는 구독 입력 필드가 있습니다: ${unknown.name}`);

  const email = field(fields, "email");
  const scopeType = field(fields, "scopeType");
  const scopeRef = field(fields, "scopeRef");
  const query = field(fields, "query");
  const frequency = field(fields, "frequency");
  const locale = field(fields, "locale");
  const consent = field(fields, "consent");
  const abuseProof = field(fields, "abuseProof");
  if (
    !email ||
    !scopeType ||
    !scopeRef ||
    !query ||
    !frequency ||
    !locale ||
    !consent ||
    !abuseProof
  )
    return blocked("createSubscription 필드 집합이 완전하지 않습니다.");

  if (!email.required || email.readonly || email.type !== "text")
    return blocked("이메일 입력 계약이 올바르지 않습니다.");
  if (!scopeType.required || scopeType.type !== "text")
    return blocked("구독 범위 입력 계약이 올바르지 않습니다.");
  if (!sameOptions(scopeType.options, Object.keys(SUBSCRIPTION_SCOPE_LABELS)))
    return blocked("구독 범위 선택지가 폐쇄형 라벨 계약과 일치하지 않습니다.");
  if (scopeRef.required || scopeRef.type !== "text")
    return blocked("구독 범위 식별자 계약이 올바르지 않습니다.");
  if (query.required || query.type !== "json")
    return blocked("검색 조건 구독 계약이 올바르지 않습니다.");
  if (!frequency.required || frequency.readonly || frequency.type !== "text")
    return blocked("구독 빈도 입력 계약이 올바르지 않습니다.");
  if (
    !sameOptions(frequency.options, Object.keys(SUBSCRIPTION_FREQUENCY_LABELS))
  )
    return blocked("구독 빈도 선택지가 폐쇄형 라벨 계약과 일치하지 않습니다.");
  if (!locale.required || !fixedString(locale))
    return blocked("서버가 확정한 언어·지역 설정이 없습니다.");
  if (!consent.required || consent.readonly || consent.type !== "boolean")
    return blocked("구독 동의 입력 계약이 올바르지 않습니다.");
  if (consent.value === true)
    return blocked("구독 동의는 미리 선택할 수 없습니다.");
  if (!abuseProof.required || abuseProof.type !== "json")
    return blocked("자동 제출 방지 계약이 올바르지 않습니다.");
  if (
    abuseProof.readonly ||
    abuseProof.value !== undefined ||
    (abuseProof.challengeAction !== undefined &&
      abuseProof.challengeAction !== OPERATION_ID)
  )
    return blocked("자동 제출 방지 증빙은 현재 구독 요청에 결속되어야 합니다.");

  const fixedScopeType = scopeValue(scopeType);
  if (scopeType.readonly && !fixedScopeType)
    return blocked("서버가 확정한 구독 범위가 올바르지 않습니다.");
  if (!scopeType.readonly && scopeType.value !== undefined)
    return blocked("편집 가능한 구독 범위에 서버 preset이 섞여 있습니다.");

  if (fixedScopeType && needsScopeRef(fixedScopeType)) {
    if (!fixedString(scopeRef)) return blocked("구독 문맥 식별자가 없습니다.");
    if (fixedScopeType === "REGION" && !isSigunguCode(String(scopeRef.value)))
      return blocked("지역 구독 시군구 코드가 올바르지 않습니다.");
  }
  if (fixedScopeType === "QUERY" && !fixedQuery(query))
    return blocked("검색 조건 구독 문맥이 없습니다.");

  const fixedFields = [scopeType, scopeRef, query, locale].filter(
    (candidate) => candidate.readonly && candidate.value !== undefined,
  );

  return {
    ready: true,
    model: {
      actionId: PUBLIC_SUBSCRIPTION_ACTION_ID,
      actionLabel: action.label,
      formAction: namedFormAction(
        PUBLIC_SUBSCRIPTION_ACTION_ID,
        runtime.search,
      ),
      idempotencyKey,
      email,
      scopeType,
      scopeRef,
      query,
      frequency,
      locale,
      consent,
      abuseProof,
      fixedFields,
      ...(fixedScopeType ? { fixedScopeType } : {}),
    },
  };
}

export function namedFormAction(actionId: string, search?: string): string {
  const query = (search ?? "")
    .replace(/^\?/, "")
    .split("&")
    .filter((part) => part && !part.startsWith("/") && !part.startsWith("%2F"))
    .join("&");
  return query ? `?/${actionId}&${query}` : `?/${actionId}`;
}

export function needsScopeRef(scopeType: string): boolean {
  return ["CASE", "AGENCY", "SUPPLIER", "REGION"].includes(scopeType);
}

export function subscriptionScopeLabel(scopeType: string): string | undefined {
  return scopeType in SUBSCRIPTION_SCOPE_LABELS
    ? SUBSCRIPTION_SCOPE_LABELS[scopeType as SubscriptionScopeType]
    : undefined;
}

export function subscriptionFrequencyLabel(
  frequency: string,
): string | undefined {
  return frequency in SUBSCRIPTION_FREQUENCY_LABELS
    ? SUBSCRIPTION_FREQUENCY_LABELS[frequency as SubscriptionFrequency]
    : undefined;
}

export function scopeReferenceLabel(scopeType: string): string {
  if (scopeType === "CASE") return "사건 식별자";
  if (scopeType === "AGENCY") return "기관 식별자";
  if (scopeType === "SUPPLIER") return "업체 식별자";
  if (scopeType === "REGION") return "시군구 코드";
  return "구독 대상 식별자";
}

export function scopeReferencePattern(scopeType: string): string | undefined {
  return scopeType === "REGION" ? "[0-9]{5}" : undefined;
}

function isSigunguCode(value: string): boolean {
  return /^\d{5}$/u.test(value);
}

function fixedString(field: ScreenField): boolean {
  return (
    field.readonly === true &&
    typeof field.value === "string" &&
    field.value.trim().length > 0
  );
}

function fixedQuery(field: ScreenField): boolean {
  if (!fixedString(field)) return false;
  try {
    const value = JSON.parse(String(field.value));
    return typeof value === "object" && value !== null && !Array.isArray(value);
  } catch {
    return false;
  }
}

function scopeValue(field: ScreenField): SubscriptionScopeType | undefined {
  return typeof field.value === "string" &&
    field.value in SUBSCRIPTION_SCOPE_LABELS
    ? (field.value as SubscriptionScopeType)
    : undefined;
}

function field(
  fields: readonly ScreenField[],
  name: (typeof FIELD_NAMES)[number],
): ScreenField | undefined {
  return fields.find((candidate) => candidate.name === name);
}

function duplicateName(fields: readonly ScreenField[]): string | undefined {
  const names = new Set<string>();
  for (const candidate of fields) {
    if (names.has(candidate.name)) return candidate.name;
    names.add(candidate.name);
  }
  return undefined;
}

function sameOptions(
  actual: readonly string[] | undefined,
  expected: readonly string[],
): boolean {
  if (!actual || actual.length !== expected.length) return false;
  const values = new Set(actual);
  return expected.every((value) => values.has(value));
}

function blocked(reason: string): PublicSubscriptionFormResult {
  return { ready: false, reason };
}
