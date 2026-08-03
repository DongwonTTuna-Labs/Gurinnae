import { DONATION_INDEPENDENCE_NOTICE } from "@gurine/ui";
import * as v from "valibot";

export const PUBLIC_REDISTRIBUTION_NOTICE =
  "이상 징후 기록이며 위법·부패의 확정이 아님";
export const SHA256_PATTERN = /^[0-9a-f]{64}$/u;

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const BASE64_PATTERN =
  /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u;
const uuid = v.pipe(v.string(), v.regex(UUID_PATTERN), v.uuid());
const sha256 = v.pipe(v.string(), v.regex(SHA256_PATTERN));
const positiveInteger = v.pipe(v.number(), v.safeInteger(), v.minValue(1));
const nonNegativeInteger = v.pipe(v.number(), v.safeInteger(), v.minValue(0));
const text = v.pipe(v.string(), v.minLength(1));
const nullableText = v.nullable(text);
const currency = v.pipe(v.string(), v.regex(/^[A-Z]{3}$/u));
const concentrationBand = v.picklist([
  "UNKNOWN",
  "LE_5_PERCENT",
  "GT_5_TO_15_PERCENT",
  "GT_15_TO_25_PERCENT",
  "GT_25_PERCENT",
]);

const envelopeSchema = v.strictObject({
  reportId: uuid,
  status: v.literal("READY"),
  reportKind: v.literal("FUNDING_DISCLOSURE"),
  revision: positiveInteger,
  notice: v.literal(PUBLIC_REDISTRIBUTION_NOTICE),
  filename: v.pipe(v.string(), v.minLength(1), v.maxLength(255)),
  mediaType: v.picklist(["application/json", "text/csv"]),
  byteLength: positiveInteger,
  contentSha256: sha256,
  contentBase64: v.pipe(v.string(), v.minLength(1), v.regex(BASE64_PATTERN)),
  format: v.picklist(["JSON", "CSV"]),
  rowCount: nonNegativeInteger,
  sourceRevisionDigest: sha256,
  projectionDigest: sha256,
  publicContentDigest: sha256,
  generatedAt: v.pipe(v.string(), v.isoTimestamp()),
});

const policyRequestsSchema = v.strictObject({
  total: nonNegativeInteger,
  accepted: nonNegativeInteger,
  partiallyAccepted: nonNegativeInteger,
  rejected: nonNegativeInteger,
  withdrawn: nonNegativeInteger,
  pending: nonNegativeInteger,
  outcomeDigest: sha256,
});

const fundingEntrySchema = v.strictObject({
  ordinal: positiveInteger,
  identityDisclosureMode: v.picklist([
    "NAMED",
    "CATEGORY_ONLY",
    "WITHHELD_LEGAL",
  ]),
  publicDisplayName: nullableText,
  withholdingPublicExplanation: nullableText,
  counterpartyCategory: text,
  fundingSourceKind: v.picklist([
    "DONATION",
    "GRANT",
    "INSTITUTIONAL_CUSTOMER_REVENUE",
    "COMMERCIAL_CUSTOMER_REVENUE",
    "SPONSORSHIP",
    "OTHER_REVIEWED",
    "MIXED",
  ]),
  amountBandLower: text,
  amountBandUpper: nullableText,
  reportingCurrency: currency,
  concentrationBand,
  denominatorUnknownReason: nullableText,
  groupingDisputeReason: nullableText,
  concentrationUnknownReason: nullableText,
  publicCaveatText: nullableText,
  purpose: text,
  conflictDisclosure: text,
  mitigationSummary: text,
  governmentRelated: v.boolean(),
  politicalPartyRelated: v.boolean(),
  procurementSupplierRelated: v.boolean(),
  investigatedSubjectRelated: v.boolean(),
  relatedParty: v.boolean(),
  publicCaseRefs: v.array(text),
  publicSourceLinks: v.array(text),
  entryDigest: sha256,
});

const fundingReportSchema = v.strictObject({
  schemaVersion: v.literal(1),
  disclosureId: uuid,
  revision: positiveInteger,
  fiscalYear: positiveInteger,
  fiscalQuarter: v.pipe(
    v.number(),
    v.safeInteger(),
    v.minValue(1),
    v.maxValue(4),
  ),
  periodStart: v.pipe(v.string(), v.isoDate()),
  periodEnd: v.pipe(v.string(), v.isoDate()),
  reportingCurrency: currency,
  concentrationBand,
  caveat: nullableText,
  purpose: text,
  policyRequests: policyRequestsSchema,
  sources: v.array(text),
  entries: v.array(fundingEntrySchema),
  effectiveAt: v.pipe(v.string(), v.isoTimestamp()),
  publishedAt: v.pipe(v.string(), v.isoTimestamp()),
  supersedesRevision: v.nullable(positiveInteger),
  sourceRevisionDigest: sha256,
  publicContentDigest: sha256,
});

const jsonArtifactSchema = v.strictObject({
  notice: v.literal(DONATION_INDEPENDENCE_NOTICE),
  projectionDigest: sha256,
  report: fundingReportSchema,
  reportId: uuid,
  schemaVersion: v.literal(1),
  sourceRevision: positiveInteger,
  sourceRevisionDigest: sha256,
});

export type TransparencyReportEnvelope = v.InferOutput<typeof envelopeSchema>;
export type TransparencyReportJsonArtifact = v.InferOutput<
  typeof jsonArtifactSchema
>;

export function parseTransparencyReportEnvelope(
  value: unknown,
): TransparencyReportEnvelope | null {
  const result = v.safeParse(envelopeSchema, value);
  return result.success ? result.output : null;
}

export function parseTransparencyReportJsonArtifact(
  value: unknown,
): TransparencyReportJsonArtifact | null {
  const result = v.safeParse(jsonArtifactSchema, value);
  return result.success ? result.output : null;
}
