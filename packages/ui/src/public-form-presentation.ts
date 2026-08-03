import type { ScreenField } from "./index";

export const DATASET_EXPORT_FORMATS = ["CSV", "JSONL", "PARQUET"] as const;

export type DatasetExportFormat = (typeof DATASET_EXPORT_FORMATS)[number];

export type PublicDatasetRecord = Readonly<{
  id: string;
  title: string;
  description: string;
  format: string;
  license: string;
  updatedAt: string;
}>;

export type PublicDatasetCard = Readonly<{
  id: string;
  title: string;
  description: string;
  format: string;
  license: string;
  updatedAt: string;
}>;

export type DatasetExportFormContract = Readonly<{
  format: ScreenField;
  filters: ScreenField;
  email: ScreenField;
  expiresInSeconds: ScreenField;
  challengeAction: string;
}>;

export type CorrectionRequestFormContract = Readonly<{
  requesterType: ScreenField;
  contactEmail: ScreenField;
  summary: ScreenField;
  requestedChanges: ScreenField;
  evidenceDescription: ScreenField;
  expectedVersion: ScreenField;
  locale?: ScreenField;
  caseSlug?: ScreenField;
  publicationRevision?: ScreenField;
  challengeAction?: string;
}>;

const DATASET_EXPORT_FIELD_NAMES = [
  "datasetId",
  "format",
  "filters",
  "email",
  "expiresInSeconds",
  "abuseProof",
] as const;

const CORRECTION_SAVE_FIELD_NAMES = [
  "requesterType",
  "contactEmail",
  "summary",
  "requestedChanges",
  "evidenceDescription",
  "expectedVersion",
] as const;

const CORRECTION_BOOTSTRAP_FIELD_NAMES = [
  "locale",
  "caseSlug",
  "publicationRevision",
  "abuseProof",
] as const;

export function publicDatasetCards(
  records: readonly PublicDatasetRecord[],
): readonly PublicDatasetCard[] {
  const seen = new Set<string>();
  return records.map((record, index) => {
    const id = requiredText(record.id, `데이터셋 ${index + 1} 식별자`);
    if (seen.has(id)) throw new Error(`중복 데이터셋 식별자: ${id}`);
    seen.add(id);
    return {
      id,
      title: requiredText(record.title, `${id} 제목`),
      description: requiredText(record.description, `${id} 설명`),
      format: requiredText(record.format, `${id} 제공 형식`),
      license: requiredText(record.license, `${id} 이용 조건`),
      updatedAt: requiredText(record.updatedAt, `${id} 갱신 시각`),
    };
  });
}

export function datasetExportFormContract(
  fields: readonly ScreenField[],
): DatasetExportFormContract {
  const indexed = exactFields(fields, DATASET_EXPORT_FIELD_NAMES);
  const datasetId = requiredField(indexed, "datasetId", "text");
  const format = requiredField(indexed, "format", "text");
  const filters = requiredField(indexed, "filters", "json");
  const email = requiredField(indexed, "email", "text");
  const expiresInSeconds = requiredField(indexed, "expiresInSeconds", "number");
  const abuseProof = requiredField(indexed, "abuseProof", "json");
  if (!datasetId.required || !format.required || !filters.required)
    throw new Error("데이터 내보내기 필수 필드 계약이 일치하지 않습니다.");
  if (!filters.readonly || filters.value === undefined)
    throw new Error("데이터 내보내기 필터는 서버 고정값이어야 합니다.");
  if (!expiresInSeconds.readonly || expiresInSeconds.value === undefined)
    throw new Error("데이터 내보내기 만료 시간은 서버 고정값이어야 합니다.");
  if (!sameStrings(format.options, DATASET_EXPORT_FORMATS))
    throw new Error("데이터 내보내기 형식 계약이 일치하지 않습니다.");
  return {
    format,
    filters,
    email,
    expiresInSeconds,
    challengeAction: abuseProof.challengeAction ?? "createDatasetExport",
  };
}

export function correctionRequestFormContract(
  fields: readonly ScreenField[],
): CorrectionRequestFormContract {
  const allowed = [
    ...CORRECTION_SAVE_FIELD_NAMES,
    ...CORRECTION_BOOTSTRAP_FIELD_NAMES,
  ];
  const indexed = exactFields(fields, allowed, CORRECTION_SAVE_FIELD_NAMES);
  const requesterType = requiredField(indexed, "requesterType", "text");
  const contactEmail = requiredField(indexed, "contactEmail", "text");
  const summary = requiredField(indexed, "summary", "text");
  const requestedChanges = requiredField(indexed, "requestedChanges", "json");
  const evidenceDescription = requiredField(
    indexed,
    "evidenceDescription",
    "text",
  );
  const expectedVersion = requiredField(indexed, "expectedVersion", "number");
  if (
    !requesterType.required ||
    !contactEmail.required ||
    !summary.required ||
    !requestedChanges.required ||
    !expectedVersion.required
  )
    throw new Error("정정 요청 필수 필드 계약이 일치하지 않습니다.");
  if (expectedVersion.value === undefined)
    throw new Error("정정 요청 기준 버전이 없습니다.");

  const bootstrapNames = CORRECTION_BOOTSTRAP_FIELD_NAMES.filter((name) =>
    indexed.has(name),
  );
  if (
    bootstrapNames.length !== 0 &&
    bootstrapNames.length !== CORRECTION_BOOTSTRAP_FIELD_NAMES.length
  )
    throw new Error("정정 요청 세션 생성 필드 계약이 일부만 존재합니다.");

  const locale = optionalTypedField(indexed, "locale", "text");
  const caseSlug = optionalTypedField(indexed, "caseSlug", "text");
  const publicationRevision = optionalTypedField(
    indexed,
    "publicationRevision",
    "number",
  );
  const abuseProof = optionalTypedField(indexed, "abuseProof", "json");
  return {
    requesterType,
    contactEmail,
    summary,
    requestedChanges,
    evidenceDescription,
    expectedVersion,
    ...(locale ? { locale } : {}),
    ...(caseSlug ? { caseSlug } : {}),
    ...(publicationRevision ? { publicationRevision } : {}),
    ...(abuseProof
      ? {
          challengeAction:
            abuseProof.challengeAction ?? "createCorrectionRequestDraft",
        }
      : {}),
  };
}

export function requestedChangesText(value: ScreenField["value"]): string {
  if (value === undefined || value === "") return "";
  let parsed: unknown = value;
  if (typeof value === "string") {
    try {
      parsed = JSON.parse(value);
    } catch {
      throw new Error("정정 요청 변경 내역이 문자열 배열이 아닙니다.");
    }
  }
  if (
    !Array.isArray(parsed) ||
    !parsed.every((entry) => typeof entry === "string")
  )
    throw new Error("정정 요청 변경 내역이 문자열 배열이 아닙니다.");
  return parsed.join("\n");
}

export function requestedChangesJson(value: string): string {
  return JSON.stringify(
    value
      .split(/\r?\n/)
      .map((entry) => entry.trim())
      .filter((entry) => entry.length > 0),
  );
}

export function namedFormAction(actionId: string, search = ""): string {
  const query = search
    .replace(/^\?/, "")
    .split("&")
    .filter((part) => part && !part.startsWith("/") && !part.startsWith("%2F"))
    .join("&");
  return query ? `?/${actionId}&${query}` : `?/${actionId}`;
}

export function hiddenFieldValue(field: ScreenField): string {
  if (field.value === undefined)
    throw new Error(`${field.name} 서버 고정값이 없습니다.`);
  return String(field.value);
}

function exactFields(
  fields: readonly ScreenField[],
  allowedNames: readonly string[],
  requiredNames: readonly string[] = allowedNames,
): ReadonlyMap<string, ScreenField> {
  const allowed = new Set(allowedNames);
  const indexed = new Map<string, ScreenField>();
  for (const field of fields) {
    if (!allowed.has(field.name))
      throw new Error(`지원하지 않는 폼 필드: ${field.name}`);
    if (indexed.has(field.name)) throw new Error(`중복 폼 필드: ${field.name}`);
    indexed.set(field.name, field);
  }
  for (const name of requiredNames) {
    if (!indexed.has(name)) throw new Error(`필수 폼 필드 누락: ${name}`);
  }
  return indexed;
}

function requiredField(
  fields: ReadonlyMap<string, ScreenField>,
  name: string,
  type: ScreenField["type"],
): ScreenField {
  const field = fields.get(name);
  if (!field) throw new Error(`필수 폼 필드 누락: ${name}`);
  if (field.type !== type) throw new Error(`${name} 필드 형식 불일치`);
  return field;
}

function optionalTypedField(
  fields: ReadonlyMap<string, ScreenField>,
  name: string,
  type: ScreenField["type"],
): ScreenField | undefined {
  const field = fields.get(name);
  if (field && field.type !== type) throw new Error(`${name} 필드 형식 불일치`);
  return field;
}

function sameStrings(
  left: readonly string[] | undefined,
  right: readonly string[],
): boolean {
  return (
    left?.length === right.length && left.every((item, i) => item === right[i])
  );
}

function requiredText(value: string, label: string): string {
  const normalized = value.trim();
  if (!normalized) throw new Error(`${label} 누락`);
  return normalized;
}
