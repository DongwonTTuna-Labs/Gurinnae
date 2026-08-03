import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import * as v from "valibot";

export type PublicExportFormat = "CSV" | "JSONL";
export type PublicExportKind = "CASES" | "CONTRACTS" | "SEARCH";

export const PUBLIC_EXPORT_NOTICE =
  "이상 징후 기록이며 위법·부패의 확정이 아님";
export const OPERATIONAL_INTERPRETATION_NOTICE =
  "이 상태는 자료의 수집·공개·검토 상태이며 위법성이나 부패 여부에 대한 판단이 아닙니다.";
const PUBLISHED_ANOMALY_NOTICE =
  "공개자료 비교에서 설명이 필요한 차이가 확인됐습니다. 현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.";
const PUBLISHED_EXPLAINED_NOTICE =
  "처음 탐지된 차이는 추가 자료에서 확인된 구성·서비스·조건의 차이로 설명됩니다. 탐지와 검증 과정을 함께 공개합니다.";
const RETRACTED_NOTICE =
  "핵심 근거의 오류로 이 게시물을 철회했습니다. 원래 주장은 더 이상 유효하지 않습니다. 오류 원인과 후속 조치를 공개합니다.";
const TEMPORARILY_RESTRICTED_NOTICE =
  "법적 사유, 권리 보호 또는 안전을 위해 공개를 일시 제한했습니다. 이 제한은 위법성이나 부패 여부에 대한 판단이 아닙니다.";

const noticeText = v.pipe(v.string(), v.minLength(1), v.maxLength(4_000));
const filterValueSchema = v.union([
  v.string(),
  v.boolean(),
  v.pipe(v.array(v.string()), v.maxLength(32)),
]);
const downloadEnvelopeSchema = v.strictObject({
  id: v.pipe(v.string(), v.minLength(1), v.maxLength(200)),
  status: v.literal("READY"),
  version: v.pipe(v.number(), v.safeInteger(), v.minValue(1)),
  notice: v.literal(PUBLIC_EXPORT_NOTICE),
  nonConclusionNotices: v.pipe(
    v.array(noticeText),
    v.maxLength(5_000),
    v.check(
      (notices) => new Set(notices).size === notices.length,
      "비확정 고지는 중복될 수 없습니다.",
    ),
  ),
  interpretationNotice: v.nullable(
    v.literal(OPERATIONAL_INTERPRETATION_NOTICE),
  ),
  filename: v.pipe(
    v.string(),
    v.minLength(1),
    v.maxLength(160),
    v.regex(/^[\p{L}\p{N}][\p{L}\p{N}._() -]*$/u),
  ),
  mediaType: v.picklist([
    "text/csv; charset=utf-8",
    "application/x-ndjson; charset=utf-8",
  ]),
  byteLength: v.pipe(v.number(), v.safeInteger(), v.minValue(0)),
  contentSha256: v.pipe(v.string(), v.regex(/^[a-f0-9]{64}$/u)),
  contentBase64: v.pipe(v.string(), v.base64()),
  format: v.picklist(["CSV", "JSONL"]),
  rowCount: v.pipe(
    v.number(),
    v.safeInteger(),
    v.minValue(0),
    v.maxValue(5_000),
  ),
  appliedFilters: v.record(v.string(), filterValueSchema),
  generatedAt: v.pipe(v.string(), v.isoTimestamp()),
});

type ExportRow = Readonly<Record<string, unknown>>;

export type VerifiedPublicDownloadPayload = Readonly<{
  bytes: Buffer;
  contentBase64: string;
  filename: string;
  mediaType: string;
  extension: "csv" | "jsonl";
}>;

export type PublicDownloadVerification = Readonly<{
  format: PublicExportFormat;
  kind: PublicExportKind;
  expectedFilters?: Readonly<
    Record<string, string | boolean | readonly string[]>
  >;
}>;

export function verifiedPublicDownloadPayload(
  value: unknown,
  verification: PublicDownloadVerification,
): VerifiedPublicDownloadPayload | undefined {
  const parsed = v.safeParse(downloadEnvelopeSchema, value);
  if (!parsed.success) return;
  const envelope = parsed.output;
  if (
    envelope.format !== verification.format ||
    envelope.mediaType !== expectedMediaType(verification.format) ||
    !envelope.filename
      .toLowerCase()
      .endsWith(expectedExtension(verification.format)) ||
    (verification.expectedFilters !== undefined &&
      !filtersEqual(envelope.appliedFilters, verification.expectedFilters))
  )
    return;

  const bytes = Buffer.from(envelope.contentBase64, "base64");
  const digest = createHash("sha256").update(bytes).digest("hex");
  if (
    bytes.toString("base64") !== envelope.contentBase64 ||
    bytes.byteLength !== envelope.byteLength ||
    digest !== envelope.contentSha256
  )
    return;
  const rows = artifactRows(bytes, verification.format, verification.kind);
  if (
    !rows ||
    rows.length !== envelope.rowCount ||
    !noticesAgree(envelope, rows, verification.format, verification.kind)
  )
    return;
  return {
    bytes,
    contentBase64: envelope.contentBase64,
    filename: envelope.filename,
    mediaType: envelope.mediaType,
    extension: verification.format === "CSV" ? "csv" : "jsonl",
  };
}

const EXPORT_HEADERS: Readonly<Record<PublicExportKind, readonly string[]>> = {
  CASES: [
    "slug",
    "title",
    "publicState",
    "summary",
    "revision",
    "updatedAt",
    "responseStatus",
    "correctionStatus",
    "nonConclusion",
    "href",
  ],
  CONTRACTS: [
    "id",
    "contractNumber",
    "title",
    "agencyName",
    "supplierName",
    "status",
    "signedAt",
    "amount",
    "currency",
    "interpretationNotice",
  ],
  SEARCH: [
    "resultType",
    "id",
    "title",
    "subtitle",
    "status",
    "summary",
    "nonConclusion",
    "interpretationNotice",
    "updatedAt",
    "href",
  ],
};

function artifactRows(
  bytes: Buffer,
  format: PublicExportFormat,
  kind: PublicExportKind,
): readonly ExportRow[] | undefined {
  const content = bytes.toString("utf8");
  if (!Buffer.from(content, "utf8").equals(bytes)) return;
  return format === "JSONL"
    ? jsonlRows(content)
    : csvRows(content, EXPORT_HEADERS[kind]);
}

function jsonlRows(content: string): readonly ExportRow[] | undefined {
  const lines = content.split("\n");
  if (lines.at(-1) === "") lines.pop();
  if (lines.length === 0 || lines.some((line) => line.length === 0)) return;
  const records: ExportRow[] = [];
  for (const rawLine of lines) {
    const line = rawLine.endsWith("\r") ? rawLine.slice(0, -1) : rawLine;
    try {
      const value: unknown = JSON.parse(line);
      if (!isRecord(value)) return;
      records.push(value);
    } catch {
      return;
    }
  }
  const first = records.shift();
  return exactRedistributionNotice(first) ? records : undefined;
}

function csvRows(
  content: string,
  expectedHeader: readonly string[],
): readonly ExportRow[] | undefined {
  const records = parseCsvRecords(content);
  if (!records || records.length < 2) return;
  const notice = records[0];
  const header = records[1];
  if (
    notice?.length !== 1 ||
    notice?.[0] !== PUBLIC_EXPORT_NOTICE ||
    !header ||
    !sameStrings(header, expectedHeader)
  )
    return;
  const rows: ExportRow[] = [];
  for (const cells of records.slice(2)) {
    if (cells.length !== header.length) return;
    rows.push(
      Object.fromEntries(header.map((name, index) => [name, cells[index]])),
    );
  }
  return rows;
}

function parseCsvRecords(content: string): string[][] | undefined {
  const records: string[][] = [];
  let record: string[] = [];
  let field = "";
  let quoted = false;
  let closedQuote = false;
  const finishRecord = () => {
    record.push(field);
    records.push(record);
    record = [];
    field = "";
    closedQuote = false;
  };

  for (let index = 0; index < content.length; index += 1) {
    const character = content[index];
    if (quoted) {
      if (character !== '"') {
        field += character;
      } else if (content[index + 1] === '"') {
        field += '"';
        index += 1;
      } else {
        quoted = false;
        closedQuote = true;
      }
      continue;
    }
    if (
      closedQuote &&
      character !== "," &&
      character !== "\r" &&
      character !== "\n"
    )
      return;
    if (character === '"') {
      if (field.length > 0) return;
      quoted = true;
    } else if (character === ",") {
      record.push(field);
      field = "";
      closedQuote = false;
    } else if (character === "\r") {
      if (content[index + 1] !== "\n") return;
      finishRecord();
      index += 1;
    } else if (character === "\n") {
      finishRecord();
    } else {
      field += character;
    }
  }
  if (quoted) return;
  if (closedQuote || field.length > 0 || record.length > 0) finishRecord();
  return records;
}

function noticesAgree(
  envelope: v.InferOutput<typeof downloadEnvelopeSchema>,
  rows: readonly ExportRow[],
  format: PublicExportFormat,
  kind: PublicExportKind,
): boolean {
  const notices: string[] = [];
  let operationalRowPresent = false;
  for (const row of rows) {
    const result = rowNotices(row, format, kind);
    if (!result) return false;
    if (result.nonConclusion && !notices.includes(result.nonConclusion))
      notices.push(result.nonConclusion);
    operationalRowPresent ||= result.operational;
  }
  const expectedInterpretation =
    kind === "CONTRACTS" || (kind === "SEARCH" && operationalRowPresent)
      ? OPERATIONAL_INTERPRETATION_NOTICE
      : null;
  return (
    sameStrings(envelope.nonConclusionNotices, notices) &&
    envelope.interpretationNotice === expectedInterpretation
  );
}

function rowNotices(
  row: ExportRow,
  format: PublicExportFormat,
  kind: PublicExportKind,
): Readonly<{ nonConclusion?: string; operational: boolean }> | undefined {
  if (kind === "CASES") {
    const nonConclusion = publicationNonConclusion(row, "publicState");
    if (
      !nonConclusion ||
      !absentOrNullNotice(row, "interpretationNotice", format)
    )
      return;
    return { nonConclusion, operational: false };
  }
  if (kind === "CONTRACTS") {
    if (
      row.interpretationNotice !== OPERATIONAL_INTERPRETATION_NOTICE ||
      !absentOrNullNotice(row, "nonConclusion", format)
    )
      return;
    return { operational: true };
  }
  return searchRowNotices(row, format);
}

function searchRowNotices(
  row: ExportRow,
  format: PublicExportFormat,
): Readonly<{ nonConclusion?: string; operational: boolean }> | undefined {
  if (typeof row.resultType !== "string" || !row.resultType.trim()) return;
  if (row.resultType === "CASE" || row.resultType === "CORRECTION") {
    const nonConclusion = publicationNonConclusion(row, "status");
    if (!nonConclusion || !nullNotice(row, "interpretationNotice", format))
      return;
    return { nonConclusion, operational: false };
  }
  if (["AGENCY", "SUPPLIER", "CONTRACT", "SOURCE"].includes(row.resultType)) {
    if (
      !nullNotice(row, "nonConclusion", format) ||
      row.interpretationNotice !== OPERATIONAL_INTERPRETATION_NOTICE
    )
      return;
    return { operational: true };
  }
  if (row.resultType === "RULE" || row.resultType === "DATASET") {
    if (
      !nullNotice(row, "nonConclusion", format) ||
      !nullNotice(row, "interpretationNotice", format)
    )
      return;
    return { operational: false };
  }
}

function publicationNonConclusion(
  row: ExportRow,
  stateKey: "publicState" | "status",
): string | undefined {
  const state = row[stateKey];
  const notice = requiredNotice(row, "nonConclusion");
  if (typeof state !== "string" || !notice) return;
  const expected = fixedPublicationNotice(state);
  if (expected === undefined) return;
  return expected === null || notice === expected ? notice : undefined;
}

function fixedPublicationNotice(state: string): string | null | undefined {
  switch (state) {
    case "PUBLISHED_ANOMALY":
      return PUBLISHED_ANOMALY_NOTICE;
    case "PUBLISHED_EXPLAINED":
      return PUBLISHED_EXPLAINED_NOTICE;
    case "RETRACTED":
      return RETRACTED_NOTICE;
    case "TEMPORARILY_RESTRICTED":
      return TEMPORARILY_RESTRICTED_NOTICE;
    case "OFFICIALLY_CONFIRMED":
    case "CORRECTED":
      return null;
    default:
      return undefined;
  }
}

function requiredNotice(row: ExportRow, name: string): string | undefined {
  const value = row[name];
  return typeof value === "string" && value.trim() ? value : undefined;
}

function nullNotice(
  row: ExportRow,
  name: string,
  format: PublicExportFormat,
): boolean {
  return (
    Object.hasOwn(row, name) &&
    (format === "CSV" ? row[name] === "" : row[name] === null)
  );
}

function absentOrNullNotice(
  row: ExportRow,
  name: string,
  format: PublicExportFormat,
): boolean {
  return !Object.hasOwn(row, name) || nullNotice(row, name, format);
}

function exactRedistributionNotice(value: ExportRow | undefined): boolean {
  return (
    value !== undefined &&
    Object.keys(value).length === 1 &&
    value.notice === PUBLIC_EXPORT_NOTICE
  );
}

function isRecord(value: unknown): value is ExportRow {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function sameStrings(
  left: readonly string[],
  right: readonly string[],
): boolean {
  return (
    left.length === right.length &&
    left.every((value, index) => value === right[index])
  );
}

function filtersEqual(
  actual: Readonly<Record<string, string | boolean | string[]>>,
  expected: Readonly<Record<string, string | boolean | readonly string[]>>,
): boolean {
  return (
    JSON.stringify(normalizedFilters(actual)) ===
    JSON.stringify(normalizedFilters(expected))
  );
}

function normalizedFilters(
  filters: Readonly<Record<string, string | boolean | readonly string[]>>,
): Readonly<Record<string, string | boolean | readonly string[]>> {
  return Object.fromEntries(
    Object.entries(filters)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([name, value]) => [
        name,
        Array.isArray(value) ? [...value] : value,
      ]),
  );
}

function expectedMediaType(format: PublicExportFormat): string {
  return format === "CSV"
    ? "text/csv; charset=utf-8"
    : "application/x-ndjson; charset=utf-8";
}

function expectedExtension(format: PublicExportFormat): string {
  return format === "CSV" ? ".csv" : ".jsonl";
}
