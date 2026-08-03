import { existsSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { parse } from "yaml";
import {
  decisionCode,
  isAllowedDecisionAction,
  requiresDecisionReason,
} from "./decision-contract";
import { ROUTE_SCREEN_CONTRACTS } from "./generated-screen-contracts";
import type { ScreenViewModel } from "./index";
import {
  SCREEN_VIEW_MODEL_REGISTRY,
  stateLabel,
  typedScreenViewModel,
} from "./screen-contract";
import { toOps004ViewModel } from "./view-models/ops-004";

const screen = (
  id: string,
  actions = [{ id: "continue", label: "다음" }],
): ScreenViewModel => ({
  id,
  title: "테스트 화면",
  route: "/test",
  archetype: "WORKSPACE",
  sections: [
    {
      id:
        ROUTE_SCREEN_CONTRACTS[id as keyof typeof ROUTE_SCREEN_CONTRACTS]
          ?.sections[0]?.id ?? "identity",
      title: "대상",
      purpose: "현재 대상과 상태를 확인합니다.",
      component: "StructuredContentSection",
      test_id:
        ROUTE_SCREEN_CONTRACTS[id as keyof typeof ROUTE_SCREEN_CONTRACTS]
          ?.sections[0]?.testId ?? "test_identity",
    },
  ],
  actions,
  states: ["loading", "success", "conflict", "forbidden"],
  dataOperations: [
    {
      operation_id: "internalQuery",
      method: "GET",
      path: "/v1/query",
      blocking: true,
    },
  ],
});

describe("typed screen contract", () => {
  it("contains the complete effective screen/section closure", () => {
    const ids = Object.keys(ROUTE_SCREEN_CONTRACTS);
    const sections = ids.reduce(
      (total, id) =>
        total +
        ROUTE_SCREEN_CONTRACTS[id as keyof typeof ROUTE_SCREEN_CONTRACTS]
          .sections.length,
      0,
    );
    expect(ids).toHaveLength(95);
    expect(new Set(ids).size).toBe(95);
    expect(ROUTE_SCREEN_CONTRACTS["PUB-035"]).toMatchObject({
      route: "/donate",
    });
    expect(sections).toBe(496);
    const emptyGeneratedSections = ids.flatMap((id) =>
      ROUTE_SCREEN_CONTRACTS[id as keyof typeof ROUTE_SCREEN_CONTRACTS].sections
        .filter((section) => section.fields.length === 0)
        .map((section) => `${id}.${section.id}`),
    );
    expect(new Set(emptyGeneratedSections)).toEqual(
      explicitlyEmptyProjectionSections(),
    );
  });
  it("has an explicit implementation for every authority component", () => {
    const components = new Set(
      Object.values(ROUTE_SCREEN_CONTRACTS).flatMap((contract) =>
        contract.sections.map((section) => section.component),
      ),
    );
    for (const component of components) {
      expect(
        existsSync(
          new URL(`./components/sections/${component}.svelte`, import.meta.url),
        ),
      ).toBe(true);
    }
  });
  it("keeps journey ownership in a closed registry", () => {
    expect(SCREEN_VIEW_MODEL_REGISTRY.response.journey).toBe("J-03");
    expect(SCREEN_VIEW_MODEL_REGISTRY.review.journey).toBe("J-07");
    expect(SCREEN_VIEW_MODEL_REGISTRY.action.journey).toBe("J-11");
  });
  it("maps response screens to J-03 and gives semantic sections", () => {
    const vm = typedScreenViewModel(screen("RSP-003"));
    expect(vm.journey).toBe("J-03");
    expect(vm.sections[0]?.fields.length).toBeGreaterThan(0);
    expect(vm.states).toContain("conflict");
    expect(vm.showsReceipt).toBe(true);
  });

  it("fails closed on a production authority component mismatch while retaining /test fixture freedom", () => {
    const production = screen("RSP-001");
    const firstSection = production.sections[0];
    if (!firstSection) throw new Error("RSP-001 must have a section");
    const mismatchedSection = {
      ...firstSection,
      component: "StructuredContentSection",
    };
    expect(() =>
      typedScreenViewModel({
        ...production,
        route: "/respond/access",
        sections: [mismatchedSection],
      }),
    ).toThrow(/screen component contract mismatch/);
    expect(() =>
      typedScreenViewModel({
        ...production,
        sections: [mismatchedSection],
      }),
    ).not.toThrow();
  });

  it("maps review screens to reasoned decisions", () => {
    const vm = typedScreenViewModel(
      screen("REV-002", [
        { id: "approve", label: "승인" },
        { id: "request-changes", label: "변경 요청" },
        { id: "reject", label: "반려" },
        { id: "recuse", label: "회피" },
      ]),
    );
    expect(vm.journey).toBe("J-07");
    expect(vm.requiresDecisionReason).toBe(true);
    expect(vm.primaryActionId).toBe("approve");
  });

  it("honors the route-owned durable-effect journey binding", () => {
    const vm = typedScreenViewModel(screen("INT-002"));
    expect(vm.journey).toBe("J-11");
    const bound = typedScreenViewModel({
      ...screen("INT-002"),
      journey: "J-11",
    });
    expect(bound.journey).toBe("J-11");
    expect(bound.showsReceipt).toBe(true);
  });

  it("uses human state labels and never exposes operation ids as section titles", () => {
    const vm = typedScreenViewModel(screen("OPS-004"));
    expect(stateLabel("forbidden")).toBe("권한 없음");
    expect(stateLabel("awaiting-query")).toBe("검색어 입력 대기");
    expect(
      vm.sections.every((section) => !section.title.includes("internalQuery")),
    ).toBe(true);
  });

  it("does not invent a primary action for read-only screens", () => {
    const vm = typedScreenViewModel(screen("PUB-004", []));
    expect(vm.primaryActionId).toBeNull();
    expect(vm.primaryActionLabel).toBeNull();
  });

  it("keeps decision dialog branches explicit and requires reasons for non-approval", () => {
    expect(decisionCode("approve")).toBe("APPROVE");
    expect(decisionCode("request-changes")).toBe("CHANGES_REQUIRED");
    expect(decisionCode("reject")).toBe("REJECT");
    expect(decisionCode("recuse")).toBe("RECUSE");
    expect(requiresDecisionReason("approve")).toBe(false);
    expect(requiresDecisionReason("reject")).toBe(true);
    expect(isAllowedDecisionAction("approve", undefined)).toBe(true);
    expect(isAllowedDecisionAction("approve", ["approve"])).toBe(true);
    expect(isAllowedDecisionAction("approve", ["request-changes"])).toBe(false);
  });

  it("projects the closed BudgetOverviewResponse and blocks incomplete evidence", () => {
    const vm = toOps004ViewModel({
      getBudgetOverview: {
        id: "budget-current",
        version: 3,
        status: "READY",
        data: {
          summary: {
            currency: "KRW",
            dailyLimit: "100",
            dailyUsed: "25",
            monthlyLimit: "1000",
            monthlyUsed: "250",
            status: "WITHIN_LIMIT",
          },
          providers: [],
          dailySeries: [],
          topCases: [],
          updatedAt: "2026-07-18T00:00:00Z",
        },
      },
    });
    expect(vm.budgetId).toBe("budget-current");
    expect(vm.budgetVersion).toBe(3);
    expect(vm.dailyUsed).toBe("25");
    // An envelope with no provider, series or case evidence is not a usable
    // budget view even when the scalar summary happens to be complete.
    expect(vm.projectionState).toBe("BLOCKED");

    const blocked = toOps004ViewModel({
      getBudgetOverview: { status: "UNKNOWN", data: { summary: {} } },
    });
    expect(blocked.projectionState).toBe("BLOCKED");
  });
});

function explicitlyEmptyProjectionSections(): Set<string> {
  const document: unknown = parse(
    readFileSync(
      new URL(
        "../../../specs/ui/screen-projection-overrides.yaml",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  if (!isRecord(document))
    throw new Error("화면 projection override 형식 오류");
  const overrides = document.screen_section_field_overrides;
  if (!isRecord(overrides))
    throw new Error("화면 projection override registry 누락");

  const result = new Set<string>();
  for (const [screenId, rawSections] of Object.entries(overrides)) {
    if (!isRecord(rawSections))
      throw new Error(`${screenId} projection override 형식 오류`);
    for (const [sectionId, fields] of Object.entries(rawSections)) {
      if (!Array.isArray(fields))
        throw new Error(`${screenId}.${sectionId} projection field 형식 오류`);
      if (fields.length === 0) result.add(`${screenId}.${sectionId}`);
    }
  }
  return result;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
