import { describe, expect, it } from "bun:test";
import legalContent from "../../../verification/generated-legal-content.json";
import operationSamples from "../../../verification/generated-operation-samples.json";
import {
  publicAgencyRows,
  publicCaseRows,
  publicContractRows,
  publicCorrectionRows,
  publicSearchRows,
  publicSourceRows,
  publicSupplierRows,
} from "./mock-api-public-ledger-fixtures";
import { publicLedgerResponseBody } from "./mock-api-public-ledgers";
import {
  OPERATIONAL_INTERPRETATION_NOTICE,
  PUBLIC_SEARCH_AWAITING_QUERY_DESCRIPTION,
  publicNonConclusion,
} from "./mock-api-public-notices";
import { handleReadRoutes } from "./mock-api-reads";
import { handleMockRequest } from "./mock-api-routes";
import {
  rowNavigationResponseBody,
  TEST_ONLY_APPROVED_RETENTION_PROVENANCE,
} from "./mock-api-row-navigation";

type JsonObject = Record<string, unknown>;

const MINIMUM_LEDGER_ROWS = 8;

function record(value: unknown): JsonObject {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    throw new Error("expected a JSON object");
  return Object.fromEntries(Object.entries(value));
}

function rows(page: JsonObject) {
  const items = page.items;
  if (!Array.isArray(items)) throw new Error("public page items are missing");
  return items.map(record);
}

function seo(response: unknown) {
  return record(record(response).seo);
}

function expectClosedSeo(response: unknown) {
  const metadata = seo(response);
  expect(String(metadata.description).trim()).not.toBe("");
  expect(metadata.openGraphDescription).toBe(metadata.description);
}

function detail(operationId: string, body: unknown, path: string): JsonObject {
  return record(
    rowNavigationResponseBody(
      operationId,
      body,
      new URL(`http://mock.test${path}`),
    ),
  );
}

async function publicPage(path: string) {
  const response = await handleMockRequest(
    new Request(`http://mock.test${path}`),
  );
  const payload = await response.text();
  if (response.status !== 200)
    throw new Error(`${path} failed OpenAPI validation: ${payload}`);
  const value: unknown = JSON.parse(payload);
  return record(value);
}

describe("populated public ledger mock", () => {
  it("keeps all six public ledgers at eight schema-valid rows", async () => {
    for (const path of [
      "/v1/cases",
      "/v1/agencies",
      "/v1/suppliers",
      "/v1/contracts",
      "/v1/corrections",
      "/v1/sources/status",
    ]) {
      expect(rows(await publicPage(path)).length).toBeGreaterThanOrEqual(
        MINIMUM_LEDGER_ROWS,
      );
    }
  });

  it("populates the default listPublicCases response used by home", async () => {
    const caseRows = rows(await publicPage("/v1/cases"));
    expect(caseRows).toHaveLength(MINIMUM_LEDGER_ROWS);
    expect(caseRows.every((row) => String(row.title).includes("계약"))).toBe(
      true,
    );
  });

  it("returns schema-valid CASE, RULE, DATASET, and SOURCE results only for a non-blank q", async () => {
    const populated = await publicPage("/v1/search?q=%20%EA%B3%84%EC%95%BD%20");
    const populatedRows = rows(populated);
    expect(
      populatedRows.filter((row) => row.resultType === "CASE"),
    ).toHaveLength(MINIMUM_LEDGER_ROWS);
    expect(
      [...new Set(populatedRows.map((row) => String(row.resultType)))].sort(),
    ).toEqual(["CASE", "DATASET", "RULE", "SOURCE"]);
    expect(record(populated.appliedFilters).q).toBe("계약");

    const blank = await publicPage("/v1/search?q=%20%20");
    expect(rows(blank)).toHaveLength(0);
    expect(record(blank.appliedFilters).q).toBe("");
  });

  it("gives awaiting-query a neutral, closed SEO envelope", () => {
    const blank = record(
      publicLedgerResponseBody(
        "searchPublicRecords",
        new URL("http://mock.test/v1/search?q=%20%20"),
      ),
    );
    const metadata = seo(blank);
    expect(rows(blank)).toHaveLength(0);
    expect(metadata.description).toBe(PUBLIC_SEARCH_AWAITING_QUERY_DESCRIPTION);
    expect(metadata.openGraphDescription).toBe(metadata.description);
  });

  it("keeps every populated public ledger description equal to Open Graph", () => {
    for (const operationId of [
      "listPublicCases",
      "listAgencies",
      "listSuppliers",
      "listContracts",
      "listCorrections",
      "listSourceStatus",
      "searchPublicRecords",
    ]) {
      expectClosedSeo(
        publicLedgerResponseBody(
          operationId,
          new URL("http://mock.test/v1/search?q=계약"),
        ),
      );
    }
  });

  it("keeps every emitted public row on its canonical notice branch", () => {
    for (const row of [...publicCaseRows, ...publicCorrectionRows]) {
      expect(row.nonConclusion).toBe(publicNonConclusion(row.publicState));
    }
    for (const row of [
      ...publicAgencyRows,
      ...publicSupplierRows,
      ...publicContractRows,
      ...publicSourceRows,
    ]) {
      expect(row.interpretationNotice).toBe(OPERATIONAL_INTERPRETATION_NOTICE);
    }
    for (const row of publicSearchRows) {
      if (row.resultType === "CASE" || row.resultType === "CORRECTION") {
        expect(String(row.nonConclusion).trim()).not.toBe("");
        expect(row.interpretationNotice).toBeNull();
      } else if (
        row.resultType === "AGENCY" ||
        row.resultType === "SUPPLIER" ||
        row.resultType === "CONTRACT" ||
        row.resultType === "SOURCE"
      ) {
        expect(row.nonConclusion).toBeNull();
        expect(row.interpretationNotice).toBe(
          OPERATIONAL_INTERPRETATION_NOTICE,
        );
      } else {
        expect(row.nonConclusion).toBeNull();
        expect(row.interpretationNotice).toBeNull();
      }
    }
  });

  it("keeps detail notices and SEO closed without leaking summary-only fields", async () => {
    const agency = detail(
      "getAgency",
      operationSamples.getAgency.body,
      `/v1/agencies/${publicAgencyRows[0]?.id}`,
    );
    const supplier = detail(
      "getSupplier",
      operationSamples.getSupplier.body,
      `/v1/suppliers/${publicSupplierRows[0]?.id}`,
    );
    const contract = detail(
      "getContract",
      operationSamples.getContract.body,
      `/v1/contracts/${publicContractRows[0]?.id}`,
    );
    const correction = detail(
      "getCorrection",
      operationSamples.getCorrection.body,
      `/v1/corrections/${publicCorrectionRows[0]?.id}`,
    );
    const source = detail(
      "getSource",
      operationSamples.getSource.body,
      `/v1/sources/${publicSourceRows[0]?.sourceId}`,
    );
    const revision = detail(
      "getPublicCaseRevision",
      operationSamples.getPublicCaseRevision.body,
      "/v1/cases/synthetic-record/revisions/3",
    );
    const reproducibility = detail(
      "getCaseReproducibility",
      operationSamples.getCaseReproducibility.body,
      "/v1/cases/synthetic-record/reproducibility",
    );
    const caseUrl = new URL("http://mock.test/v1/cases/synthetic-record");
    const caseResponse = await handleReadRoutes(new Request(caseUrl), caseUrl);
    const publicCase = record(await caseResponse.json());

    for (const response of [agency, supplier, contract]) {
      expect(response.interpretationNotice).toBe(
        OPERATIONAL_INTERPRETATION_NOTICE,
      );
      expectClosedSeo(response);
    }
    for (const response of [revision, reproducibility, publicCase])
      expectClosedSeo(response);
    expect(record(agency.seo).canonicalUrl).toBe(
      `/agencies/${publicAgencyRows[0]?.id}`,
    );
    expect(record(supplier.seo).canonicalUrl).toBe(
      `/suppliers/${publicSupplierRows[0]?.id}`,
    );
    expect(record(contract.seo).canonicalUrl).toBe(
      `/contracts/${publicContractRows[0]?.id}`,
    );
    expect(record(correction.seo).canonicalUrl).toBe(
      `/corrections/${publicCorrectionRows[0]?.id}`,
    );
    expect(record(source.seo).canonicalUrl).toBe(
      `/sources/${publicSourceRows[0]?.sourceId}`,
    );
    expect(record(source.data).interpretationNotice).toBe(
      OPERATIONAL_INTERPRETATION_NOTICE,
    );
    expectClosedSeo(source);
    expect(record(revision.seo).canonicalUrl).toBe(
      "/cases/synthetic-record/revisions/3",
    );
    expect(record(reproducibility.seo).canonicalUrl).toBe(
      "/cases/synthetic-record/reproduce",
    );
    expect(record(correction.data).nonConclusion).toBe(
      publicNonConclusion("CORRECTED"),
    );
    expect(record(correction.data).summary).toBe(
      publicCorrectionRows[0]?.summary,
    );
    expect(record(revision.content).nonConclusion).toBe(
      publicNonConclusion("PUBLISHED_ANOMALY"),
    );
    expect(reproducibility.nonConclusion).toBe(
      publicNonConclusion("PUBLISHED_ANOMALY"),
    );
    expect(publicCase.nonConclusion).toBe(
      publicNonConclusion("PUBLISHED_ANOMALY"),
    );
    expectClosedSeo(correction);

    for (const response of [agency, supplier, contract]) {
      expect(response).not.toHaveProperty("href");
      expect(response).not.toHaveProperty("caseCounts");
      expect(response).not.toHaveProperty("amount");
    }
    for (const response of [correction, revision, reproducibility, publicCase])
      expect(response).not.toHaveProperty("href");
  });

  it("keeps coverage and public system source statuses on the interpretation branch", async () => {
    const coverage = await publicPage("/v1/coverage");
    const systemStatus = await publicPage("/v1/system/status");
    const coverageSources = coverage.sources;
    const systemSources = systemStatus.sourceStatus;
    if (!Array.isArray(coverageSources) || !Array.isArray(systemSources))
      throw new Error("public source status fixtures are missing");

    for (const source of [...coverageSources, ...systemSources])
      expect(record(source).interpretationNotice).toBe(
        OPERATIONAL_INTERPRETATION_NOTICE,
      );
  });

  it("maps the rule-cases API path to the public rule-detail canonical", async () => {
    const response = await publicPage("/v1/rules/synthetic-record/cases");
    expect(record(response.seo).canonicalUrl).toBe(
      "/methodology/rules/synthetic-record",
    );
  });

  it("uses the exact canonical legal section ID sets and order", () => {
    const privacy = detail(
      "getPrivacyPolicy",
      operationSamples.getPrivacyPolicy.body,
      "/v1/content/privacy",
    );
    const terms = detail(
      "getTerms",
      operationSamples.getTerms.body,
      "/v1/content/terms",
    );
    const ids = (response: JsonObject) => {
      const sections = record(response.data).sections;
      if (!Array.isArray(sections)) throw new Error("legal sections missing");
      return sections.map((section) => String(record(section).id));
    };

    expect(ids(privacy)).toEqual([
      "controller",
      "categories",
      "purposes",
      "retention",
      "processors",
      "rights",
      "security",
      "history",
    ]);
    expect(ids(terms)).toEqual([
      "service",
      "content",
      "data",
      "prohibited",
      "liability",
      "changes",
    ]);
    expect(record(privacy.data).sections).toEqual(
      legalContent.privacy.sections,
    );
    expect(record(terms.data).sections).toEqual(legalContent.terms.sections);
  });

  it("keeps the shared legal retention fixture closed, ordered, and test-only", async () => {
    const privacy = await publicPage("/v1/content/privacy");
    const terms = await publicPage("/v1/content/terms");
    const privacyData = record(privacy.data);
    const schedules = privacyData.retentionSchedules;
    if (!Array.isArray(schedules))
      throw new Error("privacy retention schedules missing");
    expect(schedules).toHaveLength(1);

    const schedule = record(schedules[0]);
    expect(Object.keys(schedule).sort()).toEqual(
      [
        "activeDurationSeconds",
        "backupDurationSeconds",
        "effectiveAt",
        "lawfulBasis",
        "purpose",
        "recordClass",
        "reviewExpiresAt",
        "scheduleDigest",
        "terminalAction",
        "triggerKind",
      ].sort(),
    );
    expect(schedule.recordClass).toBe("AGENCY_MASTER");
    expect(TEST_ONLY_APPROVED_RETENTION_PROVENANCE).toBe("TEST_ONLY");
    expect(schedule.purpose).toBe("공익 조달 감시");
    expect(schedule.lawfulBasis).toBe("정당한 이익");
    expect(JSON.stringify(privacyData)).not.toContain("TEST_ONLY");
    expect(schedule.triggerKind).toBe("LAST_MATERIAL_USE_AT");
    expect(schedule.activeDurationSeconds).toBe(157_680_000);
    expect(schedule.backupDurationSeconds).toBe(31_536_000);
    expect(schedule.terminalAction).toBe("ANONYMIZE");
    expect(schedule.effectiveAt).toBe("2026-08-01T00:00:00Z");
    expect(schedule.reviewExpiresAt).toBe("2027-08-01T00:00:00Z");
    expect(schedule.scheduleDigest).toBe(
      "602b71c9f89f2c56453b5ddeafd10f17073a56bff4c1a0791412a5078d3c08a1",
    );
    expect(String(schedule.scheduleDigest)).toMatch(/^[a-f0-9]{64}$/u);

    const effectiveAt = Date.parse(String(schedule.effectiveAt));
    const reviewExpiresAt = Date.parse(String(schedule.reviewExpiresAt));
    expect(Number.isFinite(effectiveAt)).toBe(true);
    expect(Number.isFinite(reviewExpiresAt)).toBe(true);
    expect(reviewExpiresAt).toBeGreaterThan(effectiveAt);
    expect(record(terms.data).retentionSchedules).toEqual(schedules);
  });

  it("uses clearly fictional Korean organizations and positive KRW amounts", async () => {
    const agencyRows = rows(await publicPage("/v1/agencies"));
    const supplierRows = rows(await publicPage("/v1/suppliers"));
    const contractRows = rows(await publicPage("/v1/contracts"));

    for (const row of [...agencyRows, ...supplierRows]) {
      expect(String(row.name)).toMatch(/[가-힣]+.*\(가상\)$/u);
      expect(String(row.href)).not.toStartWith("/internal/");
    }
    for (const row of contractRows) {
      const amount = record(row.amount);
      expect(String(row.title)).toMatch(/[가-힣]/u);
      expect(amount.currency).toBe("KRW");
      expect(Number(amount.amount)).toBeGreaterThan(0);
      expect(String(row.href)).not.toStartWith("/internal/");
    }
    expect(
      JSON.stringify([...agencyRows, ...supplierRows, ...contractRows]),
    ).not.toContain("Synthetic");
  });

  it("keeps agency and supplier contract choices on the Korean public fixture", async () => {
    for (const path of [
      "/v1/agencies/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/contracts",
      "/v1/suppliers/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/contracts",
    ]) {
      const contractRows = rows(await publicPage(path));
      expect(contractRows).toHaveLength(1);
      expect(String(contractRows[0]?.title)).toMatch(/[가-힣]/u);
      expect(JSON.stringify(contractRows)).not.toContain("Synthetic");
      expect(JSON.stringify(contractRows)).not.toContain("SYNTHETIC");
    }
  });
});
