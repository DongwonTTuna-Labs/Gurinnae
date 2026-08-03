type JsonObject = Record<string, unknown>;
type BodyOverride = (body: JsonObject) => JsonObject;

const FIXTURE_TIME = "2026-07-12T00:00:00Z";
const FIXTURE_DIGEST = "d".repeat(64);

const CASE_COUNTS = {
  total: 0,
  publication: {
    neverPublished: 0,
    publishedAnomaly: 0,
    publishedExplained: 0,
    officiallyConfirmed: 0,
    corrected: 0,
    retracted: 0,
    temporarilyRestricted: 0,
  },
  investigation: {
    signalDetected: 0,
    triage: 0,
    investigating: 0,
    awaitingResponse: 0,
    editorialReview: 0,
    legalReview: 0,
    readyToPublish: 0,
    closed: 0,
  },
  resolution: {
    none: 0,
    dataError: 0,
    duplicate: 0,
    explained: 0,
    insufficientEvidence: 0,
    referredConfidential: 0,
    archived: 0,
  },
};

function fixtureUuid(namespace: string, ordinal: number) {
  return `${namespace}000000-0000-4000-8000-${String(ordinal).padStart(12, "0")}`;
}

function ordinalLabel(ordinal: number) {
  return String(ordinal).padStart(2, "0");
}

function eightRows<T>(build: (ordinal: number) => T) {
  return Array.from({ length: 8 }, (_, index) => build(index + 1));
}

function coverageModel(sourceId: string) {
  return {
    dateRange: { label: "Synthetic fixture" },
    sourceIds: [sourceId],
    recordCount: 0,
    knownGaps: [],
    freshness: { asOf: FIXTURE_TIME, status: "UNKNOWN" },
  };
}

function agencyRef(ordinal: number) {
  const label = ordinalLabel(ordinal);
  const id = fixtureUuid("70", ordinal);
  return {
    id,
    name: `Synthetic agency ${label}`,
    entityType: "AGENCY",
    href: `/agencies/${id}`,
  };
}

function contractSummary(ordinal: number) {
  const label = ordinalLabel(ordinal);
  const id = fixtureUuid("72", ordinal);
  return {
    id,
    contractNumber: `SYNTHETIC-CONTRACT-${label}`,
    title: `Synthetic contract ${label}`,
    agency: agencyRef(ordinal),
    status: "UNKNOWN",
    href: `/contracts/${id}`,
  };
}

function taskSummary(namespace: string, ordinal: number, kind: string) {
  const label = ordinalLabel(ordinal);
  const id = fixtureUuid(namespace, ordinal);
  return {
    id,
    objectType: "SYNTHETIC",
    objectId: id,
    title: `Synthetic ${kind} task ${label}`,
    status: "UNKNOWN",
    priority: "UNKNOWN",
    href: `/internal/my-work?task=${id}`,
  };
}

const agencyRows = eightRows((ordinal) => {
  const label = ordinalLabel(ordinal);
  const id = fixtureUuid("70", ordinal);
  return {
    id,
    name: `Synthetic agency ${label}`,
    agencyType: "SYNTHETIC",
    caseCounts: CASE_COUNTS,
    coverage: coverageModel(`synthetic-agency-source-${label}`),
    href: `/agencies/${id}`,
  };
});

const supplierRows = eightRows((ordinal) => {
  const label = ordinalLabel(ordinal);
  const id = fixtureUuid("71", ordinal);
  return {
    id,
    name: `Synthetic supplier ${label}`,
    caseCounts: CASE_COUNTS,
    coverage: coverageModel(`synthetic-supplier-source-${label}`),
    identityWarnings: [],
    href: `/suppliers/${id}`,
  };
});

const sourceStatusRows = eightRows((ordinal) => {
  const label = ordinalLabel(ordinal);
  return {
    sourceId: `synthetic-source-${label}`,
    displayName: `Synthetic source ${label}`,
    status: "UNKNOWN",
  };
});

const correctionRows = eightRows((ordinal) => {
  const label = ordinalLabel(ordinal);
  const id = fixtureUuid("74", ordinal);
  return {
    id,
    sourceRevision: ordinal,
    summary: `Synthetic correction ${label}`,
    reason: "Synthetic fixture",
    publishedAt: FIXTURE_TIME,
    href: `/corrections/${id}`,
  };
});

const notificationRows = eightRows((ordinal) => {
  const label = ordinalLabel(ordinal);
  const id = fixtureUuid("76", ordinal);
  return {
    id,
    notificationType: "SYNTHETIC",
    title: `Synthetic notification ${label}`,
    body: "Synthetic fixture",
    createdAt: FIXTURE_TIME,
    href: `/internal/notifications?notification=${id}`,
  };
});

const internalRuleRows = eightRows((ordinal) => {
  const label = ordinalLabel(ordinal);
  return {
    ruleId: `synthetic-rule-${label}`,
    version: `v${ordinal}`,
    status: "UNKNOWN",
    name: `Synthetic rule ${label}`,
    description: "Synthetic fixture",
    configuration: {},
    codeDigest: FIXTURE_DIGEST,
    createdAt: FIXTURE_TIME,
  };
});

function itemsOverride(items: readonly unknown[]): BodyOverride {
  return (body) => ({ ...body, items });
}

const bodyOverrides: Readonly<Record<string, BodyOverride>> = {
  listAgencies: itemsOverride(agencyRows),
  listAgencyContracts: itemsOverride([contractSummary(1)]),
  listSuppliers: itemsOverride(supplierRows),
  listSupplierContracts: itemsOverride([contractSummary(1)]),
  listContracts: itemsOverride(eightRows(contractSummary)),
  getContract: (body) => ({
    ...body,
    sourceDocuments: [
      {
        id: fixtureUuid("73", 1),
        sourceId: "synthetic-source-01",
        externalId: "synthetic-document-01",
        canonicalUrl: "https://example.invalid/synthetic-document-01",
        retrievedAt: FIXTURE_TIME,
        contentSha256: "c".repeat(64),
        locator: "synthetic-document-01",
      },
    ],
  }),
  listRules: itemsOverride([
    {
      ruleId: "synthetic-rule-01",
      name: "Synthetic rule 01",
      activeVersion: "v1",
      description: "Synthetic fixture",
      requiredFields: [],
      exclusions: [],
      limitations: [],
      formula: "synthetic_fixture",
      updatedAt: FIXTURE_TIME,
    },
  ]),
  getCoverage: (body) => ({
    ...body,
    sources: [
      {
        sourceId: "synthetic-source-01",
        displayName: "Synthetic source 01",
        status: "UNKNOWN",
        dateRange: { label: "Synthetic fixture" },
        recordCount: 0,
        freshness: { asOf: FIXTURE_TIME, status: "UNKNOWN" },
        knownGaps: [],
      },
    ],
  }),
  listSourceStatus: itemsOverride(sourceStatusRows),
  listCorrections: itemsOverride(correctionRows),
  getCorrection: (body) => {
    const data = jsonObject(body.data);
    return data
      ? {
          ...body,
          data: { ...data, caseSlug: "synthetic-case", sourceRevision: 1 },
        }
      : body;
  },
  getInternalDashboard: (body) => ({
    ...body,
    myTasks: [taskSummary("75", 1, "assigned")],
    overdueTasks: [taskSummary("77", 1, "overdue")],
  }),
  listInternalNotifications: itemsOverride(notificationRows),
  listInternalRules: itemsOverride(internalRuleRows),
};

/** Adds deterministic, schema-valid candidates for row-selection navigation. */
export function rowNavigationResponseBody(
  operationId: string,
  body: unknown,
): unknown {
  const object = jsonObject(body);
  const override = bodyOverrides[operationId];
  return object && override ? override(object) : body;
}

function jsonObject(value: unknown): JsonObject | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? Object.fromEntries(Object.entries(value))
    : undefined;
}
