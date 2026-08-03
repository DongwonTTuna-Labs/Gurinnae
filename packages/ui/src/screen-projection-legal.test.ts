import { describe, expect, it } from "vitest";
import { ROUTE_SCREEN_CONTRACTS } from "./generated-screen-contracts";
import type { ScreenViewModel } from "./index";
import { projectFetchedData, projectScreen } from "./screen-projection";
import { legalDocumentFields } from "./screen-projection-legal";

const terms = [
  "service",
  "content",
  "data",
  "prohibited",
  "liability",
  "changes",
] as const;

const privacy = [
  "controller",
  "categories",
  "purposes",
  "retention",
  "processors",
  "rights",
  "security",
  "history",
] as const;

function response(
  ids: readonly string[] = terms,
  schedules: readonly unknown[] = [retentionSchedule()],
) {
  return {
    status: "PUBLISHED",
    data: {
      status: "PUBLISHED",
      sections: ids.map((id) => ({
        id,
        heading: `${id} 법률 항목`,
        body: `${id} 법률 본문`,
      })),
      retentionSchedules: schedules,
    },
  };
}

function retentionSchedule(overrides: Readonly<Record<string, unknown>> = {}) {
  return {
    recordClass: "AGENCY_MASTER",
    purpose: "공익 조달 감시",
    lawfulBasis: "정당한 이익",
    triggerKind: "CASE_CLOSED_AT",
    activeDurationSeconds: 31_536_000,
    backupDurationSeconds: 86_400,
    terminalAction: "ANONYMIZE",
    effectiveAt: "2026-01-01T00:00:00Z",
    reviewExpiresAt: "2027-01-01T00:00:00Z",
    scheduleDigest: "a".repeat(64),
    ...overrides,
  };
}

function privacyResponse(
  schedules: readonly unknown[] = [retentionSchedule()],
) {
  return {
    status: "PUBLISHED",
    data: {
      status: "PUBLISHED",
      sections: privacy.map((id) => ({
        id,
        heading: `${id} 법률 항목`,
        body: `${id} 법률 본문`,
      })),
      retentionSchedules: schedules,
    },
  };
}

describe("closed legal document projection", () => {
  it("maps by canonical ID even when the transport array is reordered", () => {
    const projection = legalDocumentFields("PUB-032", "data", {
      getTerms: response([...terms].reverse()),
    });
    expect(projection).toMatchObject({ blocked: false });
    expect(projection?.fields[0]).toMatchObject({
      name: "data",
      value: "data 법률 본문",
      known: true,
    });
  });

  it.each([
    [terms.slice(0, -1)],
    [["service", "content", "data", "prohibited", "liability", "service"]],
    [["service", "content", "data", "prohibited", "liability", "unknown"]],
  ])("blocks missing, duplicate and unknown section IDs", (ids) => {
    expect(
      legalDocumentFields("PUB-032", "data", { getTerms: response(ids) }),
    ).toMatchObject({ blocked: true });
  });

  it("blocks an empty body or mismatched envelope status", () => {
    const emptyBody = response();
    emptyBody.data.sections[2] = {
      id: "data",
      heading: "데이터 법률 항목",
      body: "",
    };
    expect(
      legalDocumentFields("PUB-032", "data", { getTerms: emptyBody }),
    ).toMatchObject({ blocked: true });
    expect(
      legalDocumentFields("PUB-032", "data", {
        getTerms: {
          ...response(),
          data: { ...response().data, status: "DRAFT" },
        },
      }),
    ).toMatchObject({ blocked: true });
  });

  it("projects the shared approved schedule only in each document's table section", () => {
    const projection = legalDocumentFields("PUB-031", "retention", {
      getPrivacyPolicy: privacyResponse(),
    });
    expect(projection).toMatchObject({
      blocked: false,
      retentionSchedules: [
        {
          recordClass: "기관 식별 원장",
          purpose: "공익 조달 감시",
          lawfulBasis: "정당한 이익",
          trigger: "사건 종료 시각",
          activeDuration: "365일",
          backupDuration: "1일",
          terminalAction: "익명화",
          effectiveAt: "2026.01.01",
          reviewExpiresAt: "2027.01.01",
        },
      ],
    });
    expect(JSON.stringify(projection)).not.toContain("a".repeat(64));
    expect(
      legalDocumentFields("PUB-031", "controller", {
        getPrivacyPolicy: privacyResponse(),
      }),
    ).not.toHaveProperty("retentionSchedules");

    expect(
      legalDocumentFields("PUB-032", "data", { getTerms: response() }),
    ).toMatchObject({
      blocked: false,
      retentionSchedules: [{ recordClass: "기관 식별 원장" }],
    });
    expect(
      legalDocumentFields("PUB-032", "service", { getTerms: response() }),
    ).not.toHaveProperty("retentionSchedules");
  });

  it("accepts the sealed-content record class from the immutable R6d catalog", () => {
    expect(
      legalDocumentFields("PUB-032", "data", {
        getTerms: response(terms, [
          retentionSchedule({
            recordClass: "PRIVACY_REQUEST_SEALED_CONTENT",
            terminalAction: "CRYPTO_ERASE",
          }),
        ]),
      }),
    ).toMatchObject({
      blocked: false,
      retentionSchedules: [
        {
          recordClass: "권리행사 암호화 사유 본문",
          terminalAction: "암호 삭제",
        },
      ],
    });
  });

  it.each([
    ["empty", []],
    [
      "unknown record class",
      [retentionSchedule({ recordClass: "UNKNOWN_CLASS" })],
    ],
    ["duplicate record class", [retentionSchedule(), retentionSchedule()]],
    [
      "missing required duration",
      [
        retentionSchedule({
          terminalAction: "ANONYMIZE",
          activeDurationSeconds: null,
        }),
      ],
    ],
    [
      "preserve action with durations",
      [
        retentionSchedule({
          terminalAction: "PRESERVE_WITH_PARENT",
          activeDurationSeconds: 1,
          backupDurationSeconds: 1,
        }),
      ],
    ],
    [
      "expired before effective",
      [retentionSchedule({ reviewExpiresAt: "2025-01-01T00:00:00Z" })],
    ],
    ["unexpected property", [retentionSchedule({ unexpected: true })]],
  ] as const)("blocks a missing, partial, duplicate or malformed schedule set: %s", (_case, schedules) => {
    expect(
      legalDocumentFields("PUB-031", "retention", {
        getPrivacyPolicy: privacyResponse(schedules),
      }),
    ).toMatchObject({ blocked: true });
    expect(
      legalDocumentFields("PUB-032", "data", {
        getTerms: response(terms, schedules),
      }),
    ).toMatchObject({ blocked: true });
  });

  it("propagates typed schedules and specialized blocking through the browser envelope", () => {
    const current = screen("PUB-031");
    const readyEnvelope = projectFetchedData(current, {
      getPrivacyPolicy: privacyResponse(),
    });
    expect(readyEnvelope.sections.retention?.retentionSchedules).toHaveLength(
      1,
    );
    expect(
      projectScreen(current, {
        state: "success",
        data: {},
        projection: readyEnvelope,
        errors: [],
        forms: {},
      }).sections.retention,
    ).toMatchObject({ state: "READY" });

    const blockedEnvelope = projectFetchedData(current, {
      getPrivacyPolicy: privacyResponse([]),
    });
    expect(
      Object.values(blockedEnvelope.sections).every(({ blocked }) => blocked),
    ).toBe(true);

    const termsScreen = screen("PUB-032");
    const termsEnvelope = projectFetchedData(termsScreen, {
      getTerms: response(),
    });
    expect(termsEnvelope.sections.data?.retentionSchedules).toHaveLength(1);
    expect(termsEnvelope.sections.service?.retentionSchedules).toBeUndefined();
    expect(
      Object.values(
        projectScreen(current, {
          state: "success",
          data: {},
          projection: blockedEnvelope,
          errors: [],
          forms: {},
        }).sections,
      ).every(({ state }) => state === "BLOCKED"),
    ).toBe(true);
  });

  it("blocks draft legal documents even when both envelope statuses match", () => {
    const draft = response();
    draft.status = "DRAFT";
    draft.data.status = "DRAFT";
    expect(
      legalDocumentFields("PUB-032", "data", { getTerms: draft }),
    ).toMatchObject({ blocked: true });
  });
});

function screen(id: "PUB-031" | "PUB-032"): ScreenViewModel {
  const contract = ROUTE_SCREEN_CONTRACTS[id];
  const privacy = id === "PUB-031";
  return {
    id,
    title: contract.objectLabel,
    route: privacy ? "/privacy" : "/terms",
    archetype: "POLICY",
    sections: contract.sections.map((section) => ({
      id: section.id,
      title: section.id,
      purpose: privacy ? "개인정보 처리 기준" : "이용 조건",
      component: section.component,
      test_id: section.testId,
    })),
    actions: [],
    states: ["success"],
    dataOperations: [
      {
        operation_id: privacy ? "getPrivacyPolicy" : "getTerms",
        method: "GET",
        path: privacy ? "/v1/content/privacy" : "/v1/content/terms",
        blocking: true,
      },
    ],
  };
}
