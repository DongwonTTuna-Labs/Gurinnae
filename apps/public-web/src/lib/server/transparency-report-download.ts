import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import { DONATION_INDEPENDENCE_NOTICE } from "@gurine/ui";
import {
  parseTransparencyReportEnvelope,
  parseTransparencyReportJsonArtifact,
  SHA256_PATTERN,
  type TransparencyReportEnvelope,
} from "./transparency-report-contract";

export { PUBLIC_REDISTRIBUTION_NOTICE } from "./transparency-report-contract";

export type TransparencyReportFormat = "JSON" | "CSV";

export type VerifiedTransparencyReportDownload = Readonly<{
  bytes: Uint8Array;
  filename: string;
  mediaType: "application/json" | "text/csv";
  contentSha256: string;
}>;

const FUNDING_CSV_HEADERS = [
  "ordinal",
  "publicDisplay",
  "counterpartyCategory",
  "fundingSourceKind",
  "amountBandLower",
  "amountBandUpper",
  "reportingCurrency",
  "concentrationBand",
  "publicCaveat",
  "purpose",
  "conflictDisclosure",
  "mitigationSummary",
  "governmentRelated",
  "politicalPartyRelated",
  "procurementSupplierRelated",
  "investigatedSubjectRelated",
  "relatedParty",
  "publicCaseRefs",
  "publicSourceLinks",
  "entryDigest",
] as const;

export function verifyTransparencyReportDownload(
  value: unknown,
  expected: Readonly<{ reportId: string; format: TransparencyReportFormat }>,
): VerifiedTransparencyReportDownload | null {
  const envelope = parseTransparencyReportEnvelope(value);
  if (!envelope || envelope.reportId !== expected.reportId) {
    return null;
  }
  const expectedMediaType =
    expected.format === "JSON" ? "application/json" : "text/csv";
  const expectedExtension = expected.format === "JSON" ? "json" : "csv";
  if (
    envelope.format !== expected.format ||
    envelope.mediaType !== expectedMediaType ||
    envelope.filename !==
      `gurine-funding-transparency-${expected.reportId}.${expectedExtension}`
  ) {
    return null;
  }
  const expectedEncodedLength = 4 * Math.ceil(envelope.byteLength / 3);
  if (envelope.contentBase64.length !== expectedEncodedLength) return null;
  const bytes = Buffer.from(envelope.contentBase64, "base64");
  if (
    bytes.length !== envelope.byteLength ||
    bytes.toString("base64") !== envelope.contentBase64 ||
    createHash("sha256").update(bytes).digest("hex") !== envelope.contentSha256
  ) {
    return null;
  }
  if (
    expected.format === "JSON"
      ? !verifiedJsonArtifact(bytes, envelope)
      : !verifiedCsvArtifact(bytes, envelope)
  ) {
    return null;
  }
  return {
    bytes: new Uint8Array(bytes),
    filename: envelope.filename,
    mediaType: envelope.mediaType,
    contentSha256: envelope.contentSha256,
  };
}

function verifiedJsonArtifact(
  bytes: Uint8Array,
  envelope: TransparencyReportEnvelope,
): boolean {
  if (envelope.rowCount !== 1) return false;
  let value: unknown;
  try {
    value = JSON.parse(Buffer.from(bytes).toString("utf8")) as unknown;
  } catch {
    return false;
  }
  const artifact = parseTransparencyReportJsonArtifact(value);
  return (
    artifact !== null &&
    Buffer.from(JSON.stringify(value), "utf8").equals(Buffer.from(bytes)) &&
    artifact.reportId === envelope.reportId &&
    artifact.sourceRevision === envelope.revision &&
    artifact.sourceRevisionDigest === envelope.sourceRevisionDigest &&
    artifact.projectionDigest === envelope.projectionDigest &&
    artifact.report.revision === envelope.revision &&
    artifact.report.sourceRevisionDigest === envelope.sourceRevisionDigest &&
    artifact.report.publicContentDigest === envelope.publicContentDigest
  );
}

function verifiedCsvArtifact(
  bytes: Uint8Array,
  envelope: TransparencyReportEnvelope,
): boolean {
  const content = Buffer.from(bytes).toString("utf8");
  if (!Buffer.from(content, "utf8").equals(Buffer.from(bytes))) return false;
  const records = parseCsvRecords(content);
  if (!records || records.length !== envelope.rowCount + 2) return false;
  const metadata = records[0];
  const header = records[1];
  if (
    !metadata ||
    !sameStrings(metadata, [
      DONATION_INDEPENDENCE_NOTICE,
      "reportId",
      envelope.reportId,
      "revision",
      String(envelope.revision),
      "sourceRevisionDigest",
      envelope.sourceRevisionDigest,
      "projectionDigest",
      envelope.projectionDigest,
      "publicContentDigest",
      envelope.publicContentDigest,
    ]) ||
    !header ||
    !sameStrings(header, FUNDING_CSV_HEADERS)
  ) {
    return false;
  }
  return records
    .slice(2)
    .every((row, index) => validFundingCsvRow(row, index + 1));
}

function validFundingCsvRow(row: readonly string[], ordinal: number): boolean {
  if (
    row.length !== FUNDING_CSV_HEADERS.length ||
    row[0] !== String(ordinal) ||
    !SHA256_PATTERN.test(row[19] ?? "")
  ) {
    return false;
  }
  for (const index of [12, 13, 14, 15, 16]) {
    if (!matchesBoolean(row[index])) return false;
  }
  return row.every((cell) => !/^[=+\-@]/u.test(cell.trimStart()));
}

function matchesBoolean(value: string | undefined): boolean {
  return value === "true" || value === "false";
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

function parseCsvRecords(content: string): string[][] | null {
  const records: string[][] = [];
  let record: string[] = [];
  let field = "";
  let quoted = false;
  let closedQuote = false;
  for (let index = 0; index < content.length; index += 1) {
    const character = content[index];
    if (quoted) {
      if (character !== '"') field += character;
      else if (content[index + 1] === '"') {
        field += '"';
        index += 1;
      } else {
        quoted = false;
        closedQuote = true;
      }
      continue;
    }
    if (closedQuote && ![",", "\r", "\n"].includes(character ?? ""))
      return null;
    if (character === '"') {
      if (field.length > 0) return null;
      quoted = true;
    } else if (character === ",") {
      record.push(field);
      field = "";
      closedQuote = false;
    } else if (character === "\r") {
      if (content[index + 1] !== "\n") return null;
      record.push(field);
      records.push(record);
      record = [];
      field = "";
      closedQuote = false;
      index += 1;
    } else if (character === "\n") {
      return null;
    } else {
      field += character;
    }
  }
  return !quoted && record.length === 0 && field.length === 0 ? records : null;
}
