import { projectionScalarText } from "./projection-value";

export type ApprovedRetentionScheduleRow = Readonly<{
  recordClass: string;
  purpose: string;
  lawfulBasis: string;
  trigger: string;
  activeDuration: string;
  backupDuration: string;
  terminalAction: string;
  effectiveAt: string;
  reviewExpiresAt: string;
}>;

const recordClassLabels: Readonly<Record<string, string>> = {
  AGENCY_MASTER: "기관 식별 원장",
  SUPPLIER_MASTER: "업체 식별 원장",
  AGENCY_IDENTIFIER: "기관 식별자",
  SUPPLIER_IDENTIFIER: "업체 식별자",
  ENTITY_ALIAS: "기관·업체 별칭",
  RELATIONSHIP_PERSON_CONTEXT: "자연인 성명·직책 문맥",
  RELATIONSHIP_PERSON_TOPOLOGY: "자연인 관계 위상",
  ENTITY_RETENTION_SNAPSHOT: "기관·업체 보존 기준 스냅샷",
  NAMED_PERSON_PUBLICATION_GOVERNANCE: "자연인 실명 공개 판정 기록",
  RESPONSE_IDENTITY_GOVERNANCE: "소명 조직 신원 판정 기록",
  PERSON_ERASURE_GOVERNANCE: "자연인 문맥 삭제 기록",
  LEGAL_HOLD_GOVERNANCE: "법적 보존 처리 기록",
  PRIVACY_REQUEST: "개인정보 권리행사 요청",
  PRIVACY_REQUEST_TOKEN: "권리행사 일회용 토큰",
  PRIVACY_REQUEST_SEALED_CONTENT: "권리행사 암호화 사유 본문",
  PRIVACY_REQUEST_NOTICE: "권리행사 통지 기록",
  PRIVACY_REQUEST_EXECUTION: "권리행사 결정·실행 기록",
};

const triggerLabels: Readonly<Record<string, string>> = {
  CREATED_AT: "생성 시각",
  UPDATED_AT: "갱신 시각",
  CONSUMED_AT: "사용 시각",
  EXPIRES_AT: "만료 시각",
  CASE_CLOSED_AT: "사건 종료 시각",
  LAST_MATERIAL_USE_AT: "마지막 주요 사용 시각",
  SUPERSEDED_AT: "대체 시각",
  DELIVERED_AT: "전달 시각",
  TERMINAL_AT: "종료 시각",
  CONSENT_REVOKED_AT: "동의 철회 시각",
};

const terminalActionLabels: Readonly<Record<string, string>> = {
  DELETE: "삭제",
  ANONYMIZE: "익명화",
  CRYPTO_ERASE: "암호 삭제",
  PRESERVE_PUBLIC_REVISION: "공개 개정본 보존",
  PRESERVE_REFERENCED_REVISION: "참조 개정본 보존",
  PRESERVE_IDENTITY_GRAPH: "신원 그래프 보존",
  PRESERVE_WITH_PARENT: "상위 기록과 함께 보존",
};

const scheduleKeys = [
  "recordClass",
  "purpose",
  "lawfulBasis",
  "triggerKind",
  "activeDurationSeconds",
  "backupDurationSeconds",
  "terminalAction",
  "effectiveAt",
  "reviewExpiresAt",
  "scheduleDigest",
] as const;

const isoDateTime =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/u;
const lowerSha256 = /^[a-f0-9]{64}$/u;

/**
 * Convert an approved schedule set into the only retention fields that may
 * cross the browser boundary. Unknown catalog codes or malformed rows block
 * the whole table; partial legal schedules would misstate either public legal
 * document.
 */
export function parseApprovedRetentionSchedules(
  value: unknown,
): readonly ApprovedRetentionScheduleRow[] | null {
  if (!Array.isArray(value) || value.length === 0) return null;
  const rows: ApprovedRetentionScheduleRow[] = [];
  const seen = new Set<string>();
  for (const item of value) {
    const row = parseSchedule(item);
    if (!row || seen.has(row.sourceRecordClass)) return null;
    seen.add(row.sourceRecordClass);
    rows.push(row.presentation);
  }
  return rows;
}

function parseSchedule(value: unknown): Readonly<{
  sourceRecordClass: string;
  presentation: ApprovedRetentionScheduleRow;
}> | null {
  const row = exactRecord(value, scheduleKeys);
  if (!row) return null;
  const recordClass = requiredText(row.recordClass);
  const purpose = requiredText(row.purpose);
  const lawfulBasis = requiredText(row.lawfulBasis);
  const triggerKind = requiredText(row.triggerKind);
  const terminalAction = requiredText(row.terminalAction);
  const effectiveAt = dateTime(row.effectiveAt);
  const reviewExpiresAt = dateTime(row.reviewExpiresAt);
  const activeDuration = nullableDuration(row.activeDurationSeconds);
  const backupDuration = nullableDuration(row.backupDurationSeconds);
  const scheduleDigest = requiredText(row.scheduleDigest);
  const recordClassLabel = recordClass
    ? recordClassLabels[recordClass]
    : undefined;
  const trigger = triggerKind ? triggerLabels[triggerKind] : undefined;
  const terminal = terminalAction
    ? terminalActionLabels[terminalAction]
    : undefined;
  if (
    !recordClass ||
    !recordClassLabel ||
    !purpose ||
    !lawfulBasis ||
    !trigger ||
    !terminalAction ||
    !terminal ||
    !effectiveAt ||
    !reviewExpiresAt ||
    effectiveAt.epoch >= reviewExpiresAt.epoch ||
    !scheduleDigest ||
    !lowerSha256.test(scheduleDigest) ||
    activeDuration === undefined ||
    backupDuration === undefined
  )
    return null;

  const preserves = terminalAction.startsWith("PRESERVE_");
  if (
    (preserves && (activeDuration !== null || backupDuration !== null)) ||
    (!preserves && (activeDuration === null || backupDuration === null))
  )
    return null;

  return {
    sourceRecordClass: recordClass,
    presentation: {
      recordClass: recordClassLabel,
      purpose,
      lawfulBasis,
      trigger,
      activeDuration: durationText(activeDuration),
      backupDuration: durationText(backupDuration),
      terminalAction: terminal,
      effectiveAt: effectiveAt.text,
      reviewExpiresAt: reviewExpiresAt.text,
    },
  };
}

function durationText(value: number | null): string {
  if (value === null) return "계속 보존";
  return projectionScalarText("durationSeconds", value) ?? `${value}초`;
}

function nullableDuration(value: unknown): number | null | undefined {
  if (value === null) return null;
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
    ? value
    : undefined;
}

function dateTime(
  value: unknown,
): Readonly<{ text: string; epoch: number }> | null {
  const source = requiredText(value);
  if (!source || !isoDateTime.test(source)) return null;
  const epoch = Date.parse(source);
  const text = projectionScalarText("effectiveAt", source);
  return Number.isFinite(epoch) && text ? { text, epoch } : null;
}

function requiredText(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function exactRecord<const TKeys extends readonly string[]>(
  value: unknown,
  keys: TKeys,
): Record<TKeys[number], unknown> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  const actual = Object.keys(record);
  if (
    actual.length !== keys.length ||
    keys.some((key) => !Object.hasOwn(record, key))
  )
    return null;
  return record as Record<TKeys[number], unknown>;
}
