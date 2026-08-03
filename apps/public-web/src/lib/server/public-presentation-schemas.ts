import * as v from "valibot";
import {
  OPERATIONAL_INTERPRETATION_NOTICE,
  PUBLIC_EXPORT_NOTICE,
} from "./public-export-artifact";

const text = v.string();
const nonEmptyText = v.pipe(
  text,
  v.check((value) => value.trim().length > 0),
);
const integer = v.pipe(v.number(), v.integer());
const count = v.pipe(integer, v.minValue(0));
const uuid = v.pipe(text, v.uuid());
const date = v.pipe(text, v.regex(/^\d{4}-\d{2}-\d{2}$/u));
const sidoCode = v.pipe(text, v.regex(/^\d{2}$/u));
const sigunguCode = v.pipe(text, v.regex(/^\d{5}$/u));
const dateTime = v.pipe(
  text,
  v.regex(
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/u,
  ),
  v.check((value) => !Number.isNaN(Date.parse(value))),
);
const decimal = v.pipe(text, v.regex(/^-?\d+(?:\.\d+)?$/u));
export const PUBLIC_EMPTY_RESULT_NOTICE =
  "현재 선택한 조건에서 공개된 사례가 없습니다. 이는 문제 없음이나 청렴성을 의미하지 않으며, 수집 범위와 검토 상태에 따라 결과가 달라질 수 있습니다.";

export const PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE =
  OPERATIONAL_INTERPRETATION_NOTICE;

export const PUBLIC_REDISTRIBUTION_NOTICE = PUBLIC_EXPORT_NOTICE;

const operationalInterpretationNotice = v.literal(
  PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
);

function exactCounts(names: readonly string[]) {
  return v.strictObject(Object.fromEntries(names.map((name) => [name, count])));
}

function exactOptional(entries: Readonly<Record<string, v.GenericSchema>>) {
  return v.strictObject(
    Object.fromEntries(
      Object.entries(entries).map(([name, schema]) => [
        name,
        v.optional(schema),
      ]),
    ),
  );
}

function oneOf(values: string) {
  const allowed = new Set(values.split(" "));
  return v.pipe(
    text,
    v.check((value) => allowed.has(value)),
  );
}

const seoMetadata = v.strictObject({
  title: nonEmptyText,
  description: nonEmptyText,
  openGraphDescription: nonEmptyText,
  canonicalUrl: nonEmptyText,
  robots: oneOf("index,follow"),
  structuredDataType: v.optional(v.nullable(nonEmptyText)),
});

const redistributionNotice = v.literal(PUBLIC_REDISTRIBUTION_NOTICE);

function pageFields<
  TItem extends v.GenericSchema,
  TFilters extends v.GenericSchema,
>(item: TItem, filters: TFilters) {
  return {
    items: v.array(item),
    nextCursor: v.optional(text),
    totalApproximate: v.optional(integer),
    appliedFilters: filters,
    asOf: dateTime,
  };
}

function publicPage<
  TItem extends v.GenericSchema,
  TFilters extends v.GenericSchema,
>(item: TItem, filters: TFilters) {
  return v.strictObject({
    ...pageFields(item, filters),
    seo: seoMetadata,
  });
}

const caseCounts = v.strictObject({
  total: count,
  publication: exactCounts(
    "neverPublished publishedAnomaly publishedExplained officiallyConfirmed corrected retracted temporarilyRestricted".split(
      " ",
    ),
  ),
  investigation: exactCounts(
    "signalDetected triage investigating awaitingResponse editorialReview legalReview readyToPublish closed".split(
      " ",
    ),
  ),
  resolution: exactCounts(
    "none dataError duplicate explained insufficientEvidence referredConfidential archived".split(
      " ",
    ),
  ),
});

const freshness = v.strictObject({
  asOf: dateTime,
  lastSuccessfulFetchAt: v.optional(v.nullable(dateTime)),
  expectedFrequencySeconds: v.optional(v.nullable(integer)),
  lagSeconds: v.optional(v.nullable(integer)),
  status: oneOf("CURRENT DELAYED STALE UNKNOWN"),
});

const dateRange = v.strictObject({
  from: v.optional(v.nullable(date)),
  to: v.optional(v.nullable(date)),
  label: text,
});

const coverageGap = v.strictObject({
  id: text,
  scope: text,
  from: v.optional(v.nullable(dateTime)),
  to: v.optional(v.nullable(dateTime)),
  reason: text,
  impact: text,
  status: text,
});

const coverage = v.strictObject({
  dateRange,
  sourceIds: v.array(text),
  recordCount: integer,
  knownGaps: v.array(coverageGap),
  freshness,
});

export const searchPage = publicPage(
  v.strictObject({
    resultType: oneOf(
      "CASE AGENCY SUPPLIER CONTRACT RULE CORRECTION DATASET SOURCE",
    ),
    id: text,
    title: text,
    subtitle: v.optional(v.nullable(text)),
    status: v.optional(v.nullable(text)),
    summary: v.optional(v.nullable(text)),
    updatedAt: v.optional(v.nullable(dateTime)),
    href: text,
    nonConclusion: v.nullable(nonEmptyText),
    interpretationNotice: v.nullable(nonEmptyText),
  }),
  exactOptional({
    q: text,
    types: v.array(text),
    publicationState: v.array(text),
    agencyId: uuid,
    sidoCode,
    sigunguCode,
    dateFrom: date,
    dateTo: date,
    sort: oneOf("relevance updated_desc title_asc"),
  }),
);

export const casesPage = publicPage(
  v.strictObject({
    slug: text,
    title: text,
    publicState: oneOf(
      "PUBLISHED_ANOMALY PUBLISHED_EXPLAINED OFFICIALLY_CONFIRMED CORRECTED RETRACTED TEMPORARILY_RESTRICTED",
    ),
    summary: text,
    revision: integer,
    updatedAt: dateTime,
    responseStatus: v.optional(v.nullable(text)),
    correctionStatus: v.optional(v.nullable(text)),
    href: text,
    nonConclusion: nonEmptyText,
  }),
  exactOptional({
    publicationState: v.array(text),
    agencyId: uuid,
    sidoCode,
    sigunguCode,
    supplierId: uuid,
    ruleId: text,
    publishedFrom: date,
    publishedTo: date,
    hasResponse: v.boolean(),
    hasCorrection: v.boolean(),
    sort: oneOf("updated_desc published_desc title_asc"),
  }),
);

export const agenciesPage = publicPage(
  v.strictObject({
    id: uuid,
    name: text,
    agencyType: text,
    jurisdiction: v.optional(v.nullable(text)),
    sidoCode: v.nullable(sidoCode),
    sigunguCode: v.nullable(sigunguCode),
    regionCodeVersion: v.nullable(text),
    caseCounts,
    coverage,
    href: text,
    interpretationNotice: nonEmptyText,
  }),
  exactOptional({
    q: text,
    agencyType: v.array(text),
    jurisdiction: text,
  }),
);

export const suppliersPage = publicPage(
  v.strictObject({
    id: uuid,
    name: text,
    businessStatus: v.optional(v.nullable(text)),
    caseCounts,
    coverage,
    identityWarnings: v.array(text),
    href: text,
    interpretationNotice: nonEmptyText,
  }),
  exactOptional({
    q: text,
    businessStatus: v.array(text),
    identityStatus: v.array(text),
  }),
);

const entityRef = v.strictObject({
  id: uuid,
  name: text,
  entityType: oneOf("AGENCY SUPPLIER"),
  href: text,
});

export const contractsPage = publicPage(
  v.strictObject({
    id: uuid,
    contractNumber: v.optional(v.nullable(text)),
    title: text,
    agency: entityRef,
    supplier: v.optional(v.nullable(entityRef)),
    status: oneOf(
      "ANNOUNCED AWARDED ACTIVE COMPLETED CANCELLED SUPERSEDED UNKNOWN",
    ),
    signedAt: v.optional(v.nullable(date)),
    amount: v.optional(
      v.nullable(v.strictObject({ amount: decimal, currency: text })),
    ),
    href: text,
    interpretationNotice: nonEmptyText,
  }),
  exactOptional({
    q: text,
    agencyId: uuid,
    supplierId: uuid,
    contractStatus: v.array(text),
    procurementMethod: v.array(text),
    signedFrom: date,
    signedTo: date,
    amountMin: decimal,
    amountMax: decimal,
  }),
);

export const sourceStatusSummary = v.strictObject({
  sourceId: text,
  displayName: text,
  status: text,
  lastSuccessAt: v.optional(v.nullable(dateTime)),
  lagSeconds: v.optional(v.nullable(integer)),
  publicMessage: v.optional(v.nullable(text)),
  interpretationNotice: operationalInterpretationNotice,
});

export const sourcesPage = publicPage(
  sourceStatusSummary,
  exactOptional({ status: v.array(text) }),
);

const sourceCoverage = v.strictObject({
  sourceId: text,
  displayName: text,
  status: text,
  dateRange,
  recordCount: count,
  freshness,
  knownGaps: v.array(coverageGap),
  interpretationNotice: operationalInterpretationNotice,
});

export const coverageResponse = v.strictObject({
  asOf: dateTime,
  sources: v.array(sourceCoverage),
  dateRange,
  recordCounts: exactCounts(
    "sourceDocuments contracts contractLineItems agencies suppliers publicCases".split(
      " ",
    ),
  ),
  knownGaps: v.array(coverageGap),
  methodologyVersion: text,
});

export const publicSystemStatusResponse = v.strictObject({
  status: oneOf("operational degraded incident"),
  asOf: dateTime,
  affectedCapabilities: v.array(text),
  publicMessage: v.optional(text),
  sourceStatus: v.array(sourceStatusSummary),
});

const resourceIdentifier = v.strictObject({
  id: text,
  status: text,
  version: integer,
  title: v.optional(text),
  updatedAt: v.optional(dateTime),
});

const link = v.strictObject({
  rel: text,
  href: text,
  label: v.optional(text),
});

export const sourceResponse = v.strictObject({
  id: resourceIdentifier,
  version: v.optional(integer),
  status: text,
  createdAt: v.optional(dateTime),
  updatedAt: v.optional(dateTime),
  title: v.optional(text),
  summary: v.optional(text),
  data: v.strictObject({
    sourceId: text,
    displayName: text,
    owner: text,
    accessType: text,
    officialUrl: v.nullable(nonEmptyText),
    status: text,
    coverage,
    freshness,
    knownIssues: v.array(text),
    interpretationNotice: operationalInterpretationNotice,
  }),
  links: v.array(link),
  seo: seoMetadata,
});

export const correctionsPage = publicPage(
  v.strictObject({
    id: uuid,
    sourceRevision: integer,
    targetRevision: v.optional(v.nullable(integer)),
    summary: text,
    reason: text,
    publishedAt: dateTime,
    href: text,
    publicState: oneOf(
      "PUBLISHED_ANOMALY PUBLISHED_EXPLAINED OFFICIALLY_CONFIRMED CORRECTED RETRACTED TEMPORARILY_RESTRICTED",
    ),
    nonConclusion: nonEmptyText,
  }),
  exactOptional({
    publicationState: v.array(text),
    publishedFrom: date,
    publishedTo: date,
  }),
);

export const datasetsPage = publicPage(
  v.strictObject({
    id: text,
    title: text,
    description: text,
    format: text,
    coverage,
    license: text,
    updatedAt: dateTime,
    downloadUrl: v.optional(v.nullable(text)),
    redistributionNotice,
  }),
  exactOptional({ format: v.array(text) }),
);

export type SearchPage = v.InferOutput<typeof searchPage>;
export type CasesPage = v.InferOutput<typeof casesPage>;
export type AgenciesPage = v.InferOutput<typeof agenciesPage>;
export type SuppliersPage = v.InferOutput<typeof suppliersPage>;
export type ContractsPage = v.InferOutput<typeof contractsPage>;
export type SourcesPage = v.InferOutput<typeof sourcesPage>;
export type CoverageResponse = v.InferOutput<typeof coverageResponse>;
export type PublicSystemStatusResponse = v.InferOutput<
  typeof publicSystemStatusResponse
>;
export type SourceResponse = v.InferOutput<typeof sourceResponse>;
export type CorrectionsPage = v.InferOutput<typeof correctionsPage>;
