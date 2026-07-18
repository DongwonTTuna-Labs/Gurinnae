import { describe, expect, it } from "vitest";
import { existsSync } from "node:fs";
import { SCREEN_VIEW_MODEL_REGISTRY, stateLabel, typedScreenViewModel } from "./screen-contract";
import { ROUTE_SCREEN_CONTRACTS } from "./generated-screen-contracts";
import { decisionCode, requiresDecisionReason } from "./decision-contract";
import { toOps004ViewModel } from "./view-models/ops-004";
import type { ScreenViewModel } from "./index";

const screen = (id: string, actions = [{ id: "continue", label: "다음" }]): ScreenViewModel => ({
  id,
  title: "테스트 화면",
  route: "/test",
  archetype: "WORKSPACE",
  sections: [{ id: ROUTE_SCREEN_CONTRACTS[id as keyof typeof ROUTE_SCREEN_CONTRACTS]?.sections[0]?.id ?? "identity", title: "대상", purpose: "현재 대상과 상태를 확인합니다.", component: "StructuredContentSection", test_id: ROUTE_SCREEN_CONTRACTS[id as keyof typeof ROUTE_SCREEN_CONTRACTS]?.sections[0]?.testId ?? "test_identity" }],
  actions,
  states: ["loading", "success", "conflict", "forbidden"],
  dataOperations: [{ operation_id: "internalQuery", method: "GET", path: "/v1/query", blocking: true }],
});

describe("typed screen contract", () => {
  it("contains the complete effective screen/section closure", () => {
    const ids = Object.keys(ROUTE_SCREEN_CONTRACTS);
    const sections = ids.reduce((total, id) => total + ROUTE_SCREEN_CONTRACTS[id as keyof typeof ROUTE_SCREEN_CONTRACTS].sections.length, 0);
    expect(ids).toHaveLength(94);
    expect(new Set(ids).size).toBe(94);
    expect(sections).toBe(496);
    expect(ids.every((id) => ROUTE_SCREEN_CONTRACTS[id as keyof typeof ROUTE_SCREEN_CONTRACTS].sections.every((section) => section.fields.length > 0))).toBe(true);
  });
  it("has an explicit implementation for every authority component", () => {
    const components = new Set(Object.values(ROUTE_SCREEN_CONTRACTS).flatMap((contract) => contract.sections.map((section) => section.component)));
    for (const component of components) {
      expect(existsSync(new URL(`./components/sections/${component}.svelte`, import.meta.url))).toBe(true);
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
    const mismatchedSection = { ...production.sections[0]!, component: "CoverageStatement" };
    expect(() => typedScreenViewModel({
      ...production,
      route: "/respond/access",
      sections: [mismatchedSection],
    })).toThrow(/screen component contract mismatch/);
    expect(() => typedScreenViewModel({
      ...production,
      sections: [mismatchedSection],
    })).not.toThrow();
  });

  it("maps review screens to reasoned decisions", () => {
    const vm = typedScreenViewModel(screen("REV-002", [
      { id: "approve", label: "승인" },
      { id: "request-changes", label: "변경 요청" },
      { id: "reject", label: "반려" },
      { id: "recuse", label: "회피" },
    ]));
    expect(vm.journey).toBe("J-07");
    expect(vm.requiresDecisionReason).toBe(true);
    expect(vm.primaryActionId).toBe("approve");
  });

  it("honors the route-owned durable-effect journey binding", () => {
    const vm = typedScreenViewModel(screen("INT-002"));
  expect(vm.journey).toBe("J-11");
    const bound = typedScreenViewModel({ ...screen("INT-002"), journey: "J-11" });
    expect(bound.journey).toBe("J-11");
    expect(bound.showsReceipt).toBe(true);
  });

  it("uses human state labels and never exposes operation ids as section titles", () => {
    const vm = typedScreenViewModel(screen("OPS-004"));
    expect(stateLabel("forbidden")).toBe("권한 없음");
    expect(vm.sections.every((section) => !section.title.includes("internalQuery"))).toBe(true);
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
  });

  it("does not require a legacy numeric budget identity for BusinessHealth, but blocks incomplete evidence", () => {
    const vm = toOps004ViewModel({
      getBudgetOverview: {
        status: "READY",
        data: {
          asOf: "2026-07-18T00:00:00Z",
          specificationVersion: "13.1.0-business-model-r3",
          metricCatalogDigest: "a".repeat(64),
          funnel: [],
          metrics: [],
          readinessState: "READY",
          unknownSourceCount: 0,
          nextReviewAt: "2026-07-19T00:00:00Z",
        },
      },
    });
    expect(vm.budgetId).toBeNull();
    expect(vm.budgetVersion).toBeNull();
    expect(vm.specificationVersion).toBe("13.1.0-business-model-r3");
    expect(vm.metricCatalogDigest).toBe("a".repeat(64));
    expect(vm.projectionState).toBe("BLOCKED");
    expect(vm.evidenceComplete).toBe(false);
  });
});
