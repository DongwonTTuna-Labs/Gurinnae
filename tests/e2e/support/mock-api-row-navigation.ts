import { publicContractRows } from "./mock-api-public-ledger-fixtures";
import { publicLedgerResponseBody } from "./mock-api-public-ledgers";

type JsonObject = Record<string, unknown>;
type BodyOverride = (body: JsonObject) => JsonObject;

const FIXTURE_TIME = "2026-07-12T00:00:00Z";
const FIXTURE_DIGEST = "d".repeat(64);

function fixtureUuid(namespace: string, ordinal: number) {
  return `${namespace}000000-0000-4000-8000-${String(ordinal).padStart(12, "0")}`;
}

function ordinalLabel(ordinal: number) {
  return String(ordinal).padStart(2, "0");
}

function eightRows<T>(build: (ordinal: number) => T) {
  return Array.from({ length: 8 }, (_, index) => build(index + 1));
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

const sourceStatusNames = [
  "가온시 열린계약",
  "한빛도 재정공시",
  "누리시 조달공개",
  "마루군 계약현황",
  "새봄구 재정정보",
  "해솔시 입찰공고",
  "다온군 지출공개",
  "푸른구 계약대장",
] as const;

const sourceStatusRows = sourceStatusNames.map((displayName, index) => ({
  sourceId: `public-source-${ordinalLabel(index + 1)}`,
  displayName,
  status: "CURRENT",
  lastSuccessAt: FIXTURE_TIME,
  lagSeconds: 0,
}));

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
  listAgencyContracts: itemsOverride(publicContractRows.slice(0, 1)),
  listSupplierContracts: itemsOverride(publicContractRows.slice(0, 1)),
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
  listSourceStatus: (body) => ({
    ...body,
    items: sourceStatusRows,
    totalApproximate: sourceStatusRows.length,
    asOf: FIXTURE_TIME,
  }),
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
  url?: URL,
): unknown {
  const publicLedger = publicLedgerResponseBody(operationId, url);
  if (publicLedger) return publicLedger;
  const object = jsonObject(body);
  const override = bodyOverrides[operationId];
  return object && override ? override(object) : body;
}

function jsonObject(value: unknown): JsonObject | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? Object.fromEntries(Object.entries(value))
    : undefined;
}
