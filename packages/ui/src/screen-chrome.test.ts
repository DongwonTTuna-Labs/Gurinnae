import { describe, expect, it } from "vitest";
import type { ScreenRuntime, ScreenViewModel } from "./index";
import {
  breadcrumbItemsForScreen,
  contextBlockerMessage,
  errorTargetForMessage,
  responseProgressStateForStep,
  responseStepForScreen,
  stateTone,
  surfaceForScreen,
} from "./screen-chrome";

const screen = (overrides: Partial<ScreenViewModel> = {}): ScreenViewModel => ({
  id: "PUB-002",
  title: "검색",
  route: "/search",
  archetype: "SEARCH",
  sections: [],
  actions: [],
  states: ["loading", "success"],
  dataOperations: [],
  ...overrides,
});

const runtime = (overrides: Partial<ScreenRuntime> = {}): ScreenRuntime => ({
  state: "success",
  data: {},
  errors: [],
  forms: {},
  ...overrides,
});

describe("screen chrome", () => {
  it.each([
    ["PUB-001", "public"],
    ["RSP-003", "response"],
    ["AUTH-001", "auth"],
    ["INT-001", "internal"],
  ] as const)("maps %s to the %s surface", (screenId, surface) => {
    expect(surfaceForScreen(screenId)).toBe(surface);
  });

  it("keeps state tone boundaries exhaustive", () => {
    expect(stateTone("error")).toBe("status-alert");
    expect(stateTone("stale")).toBe("caution");
    expect(stateTone("success")).toBe("status");
    expect(stateTone("loading")).toBe("neutral");
  });

  it("keeps stale context guidance to one complete safety sentence", () => {
    expect(contextBlockerMessage("stale", 0)).toBe(
      "자료가 최신이 아니거나 일부만 확인되었으므로 결정 전에 기준 시각과 미확인 범위를 확인하세요.",
    );
  });

  it("builds aliased breadcrumbs without changing the current route", () => {
    expect(
      breadcrumbItemsForScreen(
        screen({ id: "PUB-004", title: "사례 상세" }),
        "/cases/case-123/revisions/3",
      ),
    ).toEqual([
      { label: "홈", href: "/" },
      { label: "사례", href: "/cases" },
      { label: "case-123", href: "/cases/case-123" },
      { label: "개정판", href: "/cases/case-123/revisions" },
      { label: "사례 상세", href: "/cases/case-123/revisions/3" },
    ]);
    expect(
      breadcrumbItemsForScreen(screen({ id: "PUB-001", route: "/" }), "/"),
    ).toEqual([]);
  });

  it("keeps the response step table and progress boundaries", () => {
    expect(responseStepForScreen("RSP-001")).toBe(1);
    expect(responseStepForScreen("RSP-003")).toBe(2);
    expect(responseStepForScreen("RSP-006")).toBe(5);
    expect(responseStepForScreen("RSP-008")).toBe(0);
    expect(responseProgressStateForStep(1, 2, 0)).toBe("complete");
    expect(responseProgressStateForStep(2, 2, 0)).toBe("in-progress");
    expect(responseProgressStateForStep(3, 2, 0)).toBe("not-started");
    expect(responseProgressStateForStep(3, 2, 1)).toBe("error");
  });

  it("maps editable field errors through the stable form-field helper", () => {
    const targetScreen = screen({
      id: "RSP-003",
      actions: [{ id: "save", label: "저장" }],
    });
    const targetRuntime = runtime({
      forms: {
        save: [
          {
            name: "answers",
            label: "답변",
            type: "text",
            required: true,
          },
          {
            name: "bodyConsent",
            label: "본문 공개 동의",
            type: "boolean",
            required: true,
          },
          {
            name: "immutable",
            label: "읽기 전용",
            type: "text",
            required: false,
            readonly: true,
          },
        ],
      },
    });

    expect(
      errorTargetForMessage(targetScreen, targetRuntime, "답변을 확인하세요"),
    ).toBe("rsp-003__field__save__answers-answer-1");
    expect(
      errorTargetForMessage(
        targetScreen,
        targetRuntime,
        "본문 공개 동의가 필요합니다",
      ),
    ).toBe("rsp-003__field__save__bodyconsent-body-consent");
    expect(
      errorTargetForMessage(targetScreen, targetRuntime, "읽기 전용 오류"),
    ).toBeNull();
  });
});
