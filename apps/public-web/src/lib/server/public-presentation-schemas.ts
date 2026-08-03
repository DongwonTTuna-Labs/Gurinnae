import * as v from "valibot";

const text = v.string();
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

function page<TItem extends v.GenericSchema, TFilters extends v.GenericSchema>(
  item: TItem,
  filters: TFilters,
) {
  return v.strictObject({
    items: v.array(item),
    nextCursor: v.optional(text),
    totalApproximate: v.optional(integer),
    appliedFilters: filters,
    asOf: dateTime,
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

const coverage = v.strictObject({
  dateRange: v.strictObject({
    from: v.optional(v.nullable(date)),
    to: v.optional(v.nullable(date)),
    label: text,
  }),
  sourceIds: v.array(text),
  recordCount: integer,
  knownGaps: v.array(
    v.strictObject({
      id: text,
      scope: text,
      from: v.optional(v.nullable(dateTime)),
      to: v.optional(v.nullable(dateTime)),
      reason: text,
      impact: text,
      status: text,
    }),
  ),
  freshness,
});

export const searchPage = page(
  v.strictObject({
    resultType: text,
    id: text,
    title: text,
    subtitle: v.optional(v.nullable(text)),
    status: v.optional(v.nullable(text)),
    summary: v.optional(v.nullable(text)),
    updatedAt: v.optional(v.nullable(dateTime)),
    href: text,
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

export const casesPage = page(
  v.strictObject({
    slug: text,
    title: text,
    publicState: oneOf(
      "NEVER_PUBLISHED PUBLISHED_ANOMALY PUBLISHED_EXPLAINED OFFICIALLY_CONFIRMED CORRECTED RETRACTED TEMPORARILY_RESTRICTED",
    ),
    summary: text,
    revision: integer,
    updatedAt: dateTime,
    responseStatus: v.optional(v.nullable(text)),
    correctionStatus: v.optional(v.nullable(text)),
    href: text,
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

export const agenciesPage = page(
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
  }),
  exactOptional({
    q: text,
    agencyType: v.array(text),
    jurisdiction: text,
  }),
);

export const suppliersPage = page(
  v.strictObject({
    id: uuid,
    name: text,
    businessStatus: v.optional(v.nullable(text)),
    caseCounts,
    coverage,
    identityWarnings: v.array(text),
    href: text,
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

export const contractsPage = page(
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

export const correctionsPage = page(
  v.strictObject({
    id: uuid,
    sourceRevision: integer,
    targetRevision: v.optional(v.nullable(integer)),
    summary: text,
    reason: text,
    publishedAt: dateTime,
    href: text,
  }),
  exactOptional({
    publicationState: v.array(text),
    publishedFrom: date,
    publishedTo: date,
  }),
);

export const datasetsPage = page(
  v.strictObject({
    id: text,
    title: text,
    description: text,
    format: text,
    coverage,
    license: text,
    updatedAt: dateTime,
    downloadUrl: v.optional(v.nullable(text)),
  }),
  exactOptional({ format: v.array(text) }),
);

export type SearchPage = v.InferOutput<typeof searchPage>;
export type CasesPage = v.InferOutput<typeof casesPage>;
export type AgenciesPage = v.InferOutput<typeof agenciesPage>;
export type SuppliersPage = v.InferOutput<typeof suppliersPage>;
export type ContractsPage = v.InferOutput<typeof contractsPage>;
export type CorrectionsPage = v.InferOutput<typeof correctionsPage>;
