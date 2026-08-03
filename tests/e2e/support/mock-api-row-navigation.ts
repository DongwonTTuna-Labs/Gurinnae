import legalContent from "../../../verification/generated-legal-content.json";
import {
  FIXTURE_AS_OF,
  publicAgencyRows,
  publicCaseRows,
  publicContractRows,
  publicCorrectionRows,
  publicSourceRows,
  publicSupplierRows,
} from "./mock-api-public-ledger-fixtures";
import { publicLedgerResponseBody } from "./mock-api-public-ledgers";
import {
  OPERATIONAL_INTERPRETATION_NOTICE,
  publicNonConclusion,
  publicSeo,
} from "./mock-api-public-notices";

type JsonObject = Record<string, unknown>;
type BodyOverride = (body: JsonObject, url?: URL) => JsonObject;

const FIXTURE_TIME = "2026-07-12T00:00:00Z";
const FIXTURE_DIGEST = "d".repeat(64);
// TEST_ONLY projection state. Canonical legal content remains launch-blocked
// until deployment inputs are approved; the mock must still exercise the
// schema-valid public rendering branch without changing that production state.
const TEST_ONLY_LEGAL_STATUS = "PUBLISHED";
export const TEST_ONLY_APPROVED_RETENTION_PROVENANCE = "TEST_ONLY" as const;

/**
 * TEST_ONLY fixture provenance: this row exercises both public legal documents;
 * it is not an approved operational schedule or a migration seed.  The digest
 * is SHA-256 over
 * `TEST_ONLY|privacy-retention|AGENCY_MASTER|LAST_MATERIAL_USE_AT|157680000|31536000|ANONYMIZE|2026-08-01T00:00:00Z|2027-08-01T00:00:00Z|v1`.
 */
const TEST_ONLY_APPROVED_RETENTION_SCHEDULES = [
  {
    recordClass: "AGENCY_MASTER",
    purpose: "공익 조달 감시",
    lawfulBasis: "정당한 이익",
    triggerKind: "LAST_MATERIAL_USE_AT",
    activeDurationSeconds: 157_680_000,
    backupDurationSeconds: 31_536_000,
    terminalAction: "ANONYMIZE",
    effectiveAt: "2026-08-01T00:00:00Z",
    reviewExpiresAt: "2027-08-01T00:00:00Z",
    scheduleDigest:
      "602b71c9f89f2c56453b5ddeafd10f17073a56bff4c1a0791412a5078d3c08a1",
  },
] as const satisfies readonly JsonObject[];

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

function pageOverride(
  items: readonly unknown[],
  title: string,
  notices: readonly string[],
): BodyOverride {
  return (body, url) => ({
    ...body,
    items,
    seo: publicSeo(title, url?.pathname ?? "/", notices),
  });
}

function publicDetailPath(url: URL | undefined, fallback: string): string {
  const pathname = url?.pathname;
  return pathname?.startsWith("/v1/") ? pathname.slice(3) : fallback;
}

function publicReproducibilityPath(url: URL | undefined): string {
  return publicDetailPath(url, "/cases").replace(
    /\/reproducibility$/u,
    "/reproduce",
  );
}

function publicRuleDetailPath(url: URL | undefined): string {
  const match = /^\/v1\/rules\/([^/]+)\/cases$/u.exec(url?.pathname ?? "");
  return match?.[1]
    ? `/methodology/rules/${match[1]}`
    : "/methodology/rules/synthetic-record";
}

function legalOverride(kind: "privacy" | "terms"): BodyOverride {
  return (body) => {
    const document = legalContent[kind];
    return {
      ...body,
      status: TEST_ONLY_LEGAL_STATUS,
      data: {
        status: TEST_ONLY_LEGAL_STATUS,
        sections: document.sections,
        retentionSchedules: TEST_ONLY_APPROVED_RETENTION_SCHEDULES,
      },
    };
  };
}

const agencyFixture = publicAgencyRows[0];
const supplierFixture = publicSupplierRows[0];
const contractFixture = publicContractRows[0];
if (!agencyFixture || !supplierFixture || !contractFixture)
  throw new Error("공개 상세 mock 기준 행 누락");

const bodyOverrides: Readonly<Record<string, BodyOverride>> = {
  listAgencyCases: pageOverride(
    publicCaseRows.slice(0, 2),
    "기관 관련 공개 사례",
    publicCaseRows.slice(0, 2).map((row) => row.nonConclusion),
  ),
  listSupplierCases: pageOverride(
    publicCaseRows.slice(0, 2),
    "업체 관련 공개 사례",
    publicCaseRows.slice(0, 2).map((row) => row.nonConclusion),
  ),
  listAgencyContracts: pageOverride(
    publicContractRows.slice(0, 1),
    "기관 관련 계약",
    [OPERATIONAL_INTERPRETATION_NOTICE],
  ),
  listSupplierContracts: pageOverride(
    publicContractRows.slice(0, 1),
    "업체 관련 계약",
    [OPERATIONAL_INTERPRETATION_NOTICE],
  ),
  listCaseRevisions: pageOverride(
    [
      {
        revision: 3,
        state: "PUBLISHED_ANOMALY",
        nonConclusion: publicNonConclusion("PUBLISHED_ANOMALY"),
        publishedAt: FIXTURE_AS_OF,
        summary: "공개 사건 개정본",
        href: "/cases/synthetic-record/revisions/3",
      },
    ],
    "사건 개정 이력",
    [publicNonConclusion("PUBLISHED_ANOMALY")],
  ),
  listRuleCases: (body, url) => ({
    ...body,
    items: publicCaseRows.slice(0, 2),
    seo: publicSeo(
      "규칙 관련 공개 사례",
      publicRuleDetailPath(url),
      publicCaseRows.slice(0, 2).map((row) => row.nonConclusion),
    ),
  }),
  getAgency: (body, url) => ({
    ...body,
    id: agencyFixture.id,
    name: agencyFixture.name,
    agencyType: agencyFixture.agencyType,
    jurisdiction: agencyFixture.jurisdiction,
    sidoCode: agencyFixture.sidoCode,
    sigunguCode: agencyFixture.sigunguCode,
    regionCodeVersion: agencyFixture.regionCodeVersion,
    coverage: agencyFixture.coverage,
    caseCountsByState: agencyFixture.caseCounts,
    recentCases: publicCaseRows.slice(0, 2),
    recentContracts: publicContractRows.slice(0, 1),
    interpretationNotice: OPERATIONAL_INTERPRETATION_NOTICE,
    seo: publicSeo("기관 상세", publicDetailPath(url, "/agencies"), [
      OPERATIONAL_INTERPRETATION_NOTICE,
    ]),
  }),
  getSupplier: (body, url) => ({
    ...body,
    id: supplierFixture.id,
    name: supplierFixture.name,
    businessStatus: supplierFixture.businessStatus,
    coverage: supplierFixture.coverage,
    caseCountsByState: supplierFixture.caseCounts,
    recentCases: publicCaseRows.slice(0, 2),
    recentContracts: publicContractRows.slice(0, 1),
    interpretationNotice: OPERATIONAL_INTERPRETATION_NOTICE,
    seo: publicSeo("업체 상세", publicDetailPath(url, "/suppliers"), [
      OPERATIONAL_INTERPRETATION_NOTICE,
    ]),
  }),
  getContract: (body, url) => ({
    ...body,
    id: contractFixture.id,
    contractNumber: contractFixture.contractNumber,
    title: contractFixture.title,
    agency: contractFixture.agency,
    supplier: contractFixture.supplier,
    status: contractFixture.status,
    signedAt: contractFixture.signedAt,
    currency: "KRW",
    originalAmount: contractFixture.amount,
    currentAmount: contractFixture.amount,
    lineItems: [],
    changes: [],
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
    normalizationWarnings: [],
    relatedCases: publicCaseRows.slice(0, 2),
    interpretationNotice: OPERATIONAL_INTERPRETATION_NOTICE,
    seo: publicSeo("계약 상세", publicDetailPath(url, "/contracts"), [
      OPERATIONAL_INTERPRETATION_NOTICE,
    ]),
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
        interpretationNotice: OPERATIONAL_INTERPRETATION_NOTICE,
      },
    ],
  }),
  getSource: (body, url) => {
    const data = jsonObject(body.data);
    const source = publicSourceRows[0];
    return data && source
      ? {
          ...body,
          status: source.status,
          data: {
            ...data,
            sourceId: source.sourceId,
            displayName: source.displayName,
            owner: "가상 공개 데이터 제공기관",
            accessType: "PUBLIC",
            officialUrl: "https://example.invalid/public-source-01",
            status: source.status,
            coverage: {
              dateRange: { label: "2025년 이후 공개자료" },
              sourceIds: [source.sourceId],
              recordCount: 128,
              knownGaps: [],
              freshness: {
                asOf: FIXTURE_TIME,
                lastSuccessfulFetchAt: source.lastSuccessAt,
                lagSeconds: source.lagSeconds,
                status: "CURRENT",
              },
            },
            freshness: {
              asOf: FIXTURE_TIME,
              lastSuccessfulFetchAt: source.lastSuccessAt,
              lagSeconds: source.lagSeconds,
              status: "CURRENT",
            },
            knownIssues: [],
            interpretationNotice: source.interpretationNotice,
          },
          seo: publicSeo(
            "데이터 출처 상세",
            publicDetailPath(url, "/sources"),
            [source.interpretationNotice],
          ),
        }
      : body;
  },
  getPublicSystemStatus: (body) => ({
    ...body,
    sourceStatus: publicSourceRows,
  }),
  getCorrection: (body, url) => {
    const data = jsonObject(body.data);
    const correction = publicCorrectionRows[0];
    return data && correction
      ? {
          ...body,
          data: {
            ...data,
            id: correction.id,
            caseSlug: "synthetic-case",
            sourceRevision: correction.sourceRevision,
            targetRevision: correction.targetRevision,
            summary: correction.summary,
            reason: correction.reason,
            publicState: correction.publicState,
            nonConclusion: correction.nonConclusion,
            publishedAt: correction.publishedAt,
          },
          seo: publicSeo("정정 상세", publicDetailPath(url, "/corrections"), [
            correction.nonConclusion,
          ]),
        }
      : body;
  },
  getPublicCaseRevision: (body, url) => {
    const content = jsonObject(body.content);
    const caseCard = jsonObject(content?.case);
    const notice = publicNonConclusion("PUBLISHED_ANOMALY");
    return content && caseCard
      ? {
          ...body,
          slug: "synthetic-record",
          revision: 3,
          isLatest: true,
          publishedAt: FIXTURE_AS_OF,
          content: {
            ...content,
            case: {
              ...caseCard,
              slug: "synthetic-record",
              title: "공개 사건 개정본",
              publicState: "PUBLISHED_ANOMALY",
              summary: "공개 사건 개정본 요약",
              revision: 3,
              updatedAt: FIXTURE_AS_OF,
              nonConclusion: notice,
              href: "/cases/synthetic-record",
            },
            agencyName: "누리샘시 생활환경국(가상)",
            contractName: "공공청사 냉난방 설비 정기점검 용역",
            amount: { amount: "48600000", currency: "KRW" },
            nonConclusion: notice,
          },
          seo: publicSeo("사건 개정본", publicDetailPath(url, "/cases"), [
            notice,
          ]),
        }
      : body;
  },
  getCaseReproducibility: (body, url) => {
    const notice = publicNonConclusion("PUBLISHED_ANOMALY");
    return {
      ...body,
      caseSlug: "synthetic-record",
      nonConclusion: notice,
      seo: publicSeo("사건 재현 정보", publicReproducibilityPath(url), [
        notice,
      ]),
    };
  },
  getPrivacyPolicy: legalOverride("privacy"),
  getTerms: legalOverride("terms"),
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
  return object && override ? override(object, url) : body;
}

function jsonObject(value: unknown): JsonObject | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? Object.fromEntries(Object.entries(value))
    : undefined;
}
