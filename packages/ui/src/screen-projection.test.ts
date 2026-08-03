import { describe, expect, it } from "vitest";
import { ROUTE_SCREEN_CONTRACTS } from "./generated-screen-contracts";
import type { ScreenRuntime, ScreenViewModel } from "./index";
import {
  emptyScreenProjection,
  projectFetchedData,
  projectScreen,
} from "./screen-projection";

function screen(id: string): ScreenViewModel {
  const contract =
    ROUTE_SCREEN_CONTRACTS[id as keyof typeof ROUTE_SCREEN_CONTRACTS];
  if (!contract) throw new Error(`unknown test screen: ${id}`);
  return {
    id,
    title: contract.objectLabel,
    route: "/test",
    archetype: "WORKSPACE",
    sections: contract.sections.map((section) => ({
      id: section.id,
      title: section.id,
      purpose: "현재 상태와 다음 행동을 확인합니다.",
      component: section.component ?? "StructuredContentSection",
      test_id: section.testId,
    })),
    actions: [],
    states: ["success"],
    dataOperations: [
      {
        operation_id: "internalQuery",
        method: "GET",
        path: "/v1/query",
        blocking: true,
      },
    ],
  };
}

const runtime = (
  screenId: string,
  projection?: ScreenRuntime["projection"],
): ScreenRuntime => ({
  state: "success",
  // This intentionally contains a DTO-shaped value.  It must never be used
  // when the server projection envelope is absent.
  data: { internalQuery: { summary: "raw DTO must not render" } },
  errors: [],
  forms: {},
  ...(projection ? { projection } : {}),
  pathname: `/${screenId.toLowerCase()}`,
});
describe("closed screen projection", () => {
  it("fails closed instead of guessing from operation DTOs", () => {
    const current = screen("PUB-004");
    const projection = projectScreen(current, runtime(current.id));
    const fields = Object.values(projection.sections).flatMap(
      (section) => section.fields,
    );
    expect(fields.length).toBeGreaterThan(0);
    expect(fields.every((field) => field.known === false)).toBe(true);
    expect(
      Object.values(projection.sections).every(
        (section) => section.state === "UNKNOWN",
      ),
    ).toBe(true);
    expect(
      fields.every(
        (field) =>
          field.source.startsWith("authority:") || field.source === "redacted",
      ),
    ).toBe(true);
    expect(
      fields.some((field) => field.value === "raw DTO must not render"),
    ).toBe(false);
  });
  it("accepts only a matching allowlist envelope and preserves its source contract", () => {
    const current = screen("PUB-004");
    const envelope = emptyScreenProjection(current);
    const firstSection = current.sections[0];
    if (!firstSection) throw new Error("test screen has no section");
    const firstField =
      ROUTE_SCREEN_CONTRACTS[current.id as keyof typeof ROUTE_SCREEN_CONTRACTS]
        .sections[0]?.fields[0];
    if (!firstField) throw new Error("test screen has no typed field");
    const baseSection = envelope.sections[firstSection.id];
    if (!baseSection) throw new Error("test screen has no projection section");
    const enriched: ScreenRuntime["projection"] = {
      ...envelope,
      sections: {
        ...envelope.sections,
        [firstSection.id]: {
          ...baseSection,
          blocked: baseSection.blocked,
          fields: {
            ...baseSection.fields,
            [firstField]: {
              value: "확인된 값",
              known: true,
              source: `authority:${current.id}.${firstSection.id}.${firstField}`,
            },
          },
        },
      },
    };
    const projection = projectScreen(current, runtime(current.id, enriched));
    expect(projection.sections[firstSection.id]?.fields[0]?.value).toBe(
      "확인된 값",
    );
    expect(projection.sections[firstSection.id]?.fields[0]?.source).toBe(
      `authority:${current.id}.${firstSection.id}.${firstField}`,
    );
  });
  it("ignores an envelope addressed to another screen", () => {
    const current = screen("PUB-004");
    const other = {
      ...emptyScreenProjection(screen("PUB-005")),
      screenId: "PUB-005",
    };
    const projection = projectScreen(current, runtime(current.id, other));
    const fields = Object.values(projection.sections).flatMap(
      (section) => section.fields,
    );
    expect(fields.every((field) => field.known === false)).toBe(true);
  });
  it("passes the operation data map to specialized journey mappers", () => {
    const current = screen("RSP-003");
    const data = {
      getResponseDraft: {
        requestId: "req-123",
        version: 4,
        answers: [{ questionId: "q-1", questionLabel: "질문", text: "답변" }],
        publicationConsent: {
          bodyConsent: true,
          redactionAcknowledged: true,
        },
      },
      saveResponseDraft: { status: "SAVED", aggregateVersion: 4 },
    };
    const projection = projectScreen(current, {
      state: "success",
      data: {},
      projection: projectFetchedData(current, data),
      errors: [],
      forms: {},
      pathname: "/respond/answer",
    });
    const progress = projection.sections.progress;
    const questions = projection.sections.questions;
    expect(
      progress?.fields.find((field) => field.name === "requestId")?.value,
    ).toBe("req-123");
    expect(
      questions?.fields.find((field) => field.name === "answers")?.value,
    ).toBe(1);
    expect(projection.state).toBe("PARTIAL");
  });
  it("rejects a non-Korean response question label", () => {
    const current = screen("RSP-003");
    const data = {
      getResponseDraft: {
        requestId: "req-123",
        version: 4,
        answers: [
          { questionId: "q-1", questionLabel: "why Material", text: "답변" },
        ],
      },
    };
    expect(() =>
      projectScreen(current, {
        state: "success",
        data: {},
        projection: projectFetchedData(current, data),
        errors: [],
        forms: {},
        pathname: "/respond/answer",
      }),
    ).toThrowError("한국어 문맥 라벨 계약 위반: why Material");
  });
  it("maps the nested FundingContentResponse sections into a closed PUB-023 projection", () => {
    const current = screen("PUB-023");
    const data = {
      getFundingContent: {
        status: "PUBLISHED",
        data: {
          sections: [
            {
              id: "principles",
              heading: "독립성 원칙",
              body: "후원자와 편집의 방화벽",
            },
            { id: "income", heading: "재원", body: "금액대 UNKNOWN" },
            { id: "expenses", heading: "비용", body: "비용 UNKNOWN" },
            { id: "donors", heading: "공개 기준", body: "15% oversight" },
            { id: "conflicts", heading: "이해상충", body: "회피·독립 검토" },
            { id: "reports", heading: "보고서", body: "보고서 없음" },
          ],
        },
      },
      listTransparencyReports: { items: [] },
    };
    const projection = projectScreen(current, {
      state: "success",
      data: {},
      projection: projectFetchedData(current, data),
      errors: [],
      forms: {},
      pathname: "/about/funding",
    });
    expect(
      projection.sections.principles?.fields.find(
        (field) => field.name === "principles",
      )?.known,
    ).toBe(true);
    expect(
      projection.sections.income?.fields.find(
        (field) => field.name === "income",
      )?.value,
    ).toBe("금액대 UNKNOWN");
    expect(
      projection.sections.conflicts?.fields.find(
        (field) => field.name === "conflicts",
      )?.known,
    ).toBe(true);
    expect(projection.sections.reports?.state).toBe("READY");
    expect(projection.state).toBe("READY");
  });
  it("rejects a non-Korean funding-content heading", () => {
    const current = screen("PUB-023");
    const data = {
      getFundingContent: {
        status: "PUBLISHED",
        data: {
          sections: [
            { id: "principles", heading: "why Material", body: "본문" },
          ],
        },
      },
    };
    expect(() =>
      projectScreen(current, {
        state: "success",
        data: {},
        projection: projectFetchedData(current, data),
        errors: [],
        forms: {},
        pathname: "/about/funding",
      }),
    ).toThrowError("한국어 문맥 라벨 계약 위반: why Material");
  });
  it("materializes generated authority operation bindings", () => {
    const current = screen("RSP-003");
    const envelope = projectFetchedData(current, {
      getResponseDraft: { status: "DRAFT" },
    });
    const progress = envelope.sections.progress;
    expect(progress?.fields.status).toMatchObject({
      value: "DRAFT",
      known: true,
      source: "getResponseDraft.$.status",
    });
  });
  it("renders the authoritative public-case answer fields instead of an empty fallback", () => {
    const current = screen("PUB-004");
    const envelope = projectFetchedData(current, {
      getPublicCase: {
        status: "PUBLISHED",
        publicState: "UNDER_REVIEW",
        revision: 3,
        freshness: { asOf: "2026-07-19T00:00:00Z", state: "FRESH" },
        summary: "계약 이행 여부를 공개 검토 중입니다.",
        confirmedFacts: [{ id: "fact-1", text: "공개 원문과 대조됨" }],
        criticalUnknowns: [{ id: "unknown-1", text: "후속 자료 미제출" }],
        limitations: ["제공된 원문 범위"],
        partyResponses: [{ party: "기관", status: "RECEIVED" }],
        claims: [{ id: "claim-1", status: "SUPPORTED" }],
        timeline: [{ at: "2026-07-18T00:00:00Z", event: "공개" }],
        corrections: [],
      },
    });
    expect(envelope.sections.status?.fields.publicState?.value).toBe(
      "UNDER_REVIEW",
    );
    expect(envelope.sections.known?.fields.summary?.value).toContain(
      "계약 이행",
    );
    expect(envelope.sections.known?.fields.confirmedFacts?.known).toBe(true);
    expect(envelope.sections.unknown?.fields.criticalUnknowns?.known).toBe(
      true,
    );
    expect(envelope.sections.evidence?.fields.claims?.known).toBe(true);
    expect(envelope.sections.timeline?.fields.timeline?.known).toBe(true);
  });
  it("binds every PUB-004 section to its exact getPublicCase response field", () => {
    const current = screen("PUB-004");
    const envelope = projectFetchedData(current, {
      getPublicCase: {
        slug: "e2e-case",
        title: "공개 사건",
        publicState: "PUBLISHED_ANOMALY",
        revision: 7,
        publishedAt: "2026-07-12T00:00:00Z",
        updatedAt: "2026-07-13T00:00:00Z",
        summary: "확인된 요약",
        confirmedFacts: [{ id: "fact-1", text: "확인된 사실" }],
        criticalUnknowns: [{ id: "unknown-1", text: "미확인" }],
        limitations: ["공개자료 범위"],
        partyResponses: [{ party: "기관", status: "RECEIVED" }],
        signals: [{ id: "signal-1", state: "OPEN" }],
        comparison: { cohort: "동일 단위" },
        counterEvidence: [{ id: "counter-1", text: "반대 근거" }],
        claims: [{ id: "claim-1", text: "주장" }],
        evidence: [{ id: "evidence-1", locator: "p.2" }],
        timeline: [{ id: "event-1", label: "공개" }],
        corrections: [{ id: "correction-1", state: "NONE" }],
        freshness: { status: "CURRENT", asOf: "2026-07-13T00:00:00Z" },
      },
    });
    expect(envelope.sections.status?.fields.publicState).toMatchObject({
      value: "PUBLISHED_ANOMALY",
      known: true,
      source: "getPublicCase.$.publicState",
    });
    expect(envelope.sections.known?.fields.confirmedFacts).toMatchObject({
      known: true,
      source: "getPublicCase.$.confirmedFacts",
    });
    expect(envelope.sections.unknown?.fields.criticalUnknowns?.known).toBe(
      true,
    );
    expect(envelope.sections.response?.fields.partyResponses?.known).toBe(true);
    expect(envelope.sections.evidence?.fields.evidence?.known).toBe(true);
    expect(envelope.sections.status?.fields).not.toHaveProperty("status");
    expect(envelope.sections.known?.fields).not.toHaveProperty("known");
    expect(Object.keys(envelope.sections)).toEqual([
      "status",
      "known",
      "unknown",
      "response",
      "comparison",
      "counter",
      "evidence",
      "timeline",
      "revision",
    ]);
    expect(Object.keys(envelope.sections.status?.fields ?? {})).toEqual([
      "slug",
      "title",
      "publicState",
      "revision",
      "publishedAt",
      "updatedAt",
      "freshness",
    ]);
  });
});
