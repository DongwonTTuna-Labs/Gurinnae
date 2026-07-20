import { describe, expect, it } from "vitest";
import type { ScreenRuntime, ScreenViewModel } from "./index";
import { localActionHref } from "./local-actions";

const runtime = (data: Record<string, unknown> = {}): ScreenRuntime => ({
  state: "success",
  pathname: "/contracts",
  data,
  errors: [],
  forms: {},
});

const screen = (id: string, route: string): ScreenViewModel => ({
  id,
  title: id,
  route,
  archetype: "SEARCH_INDEX",
  sections: [],
  actions: [],
  states: [],
  dataOperations: [],
});

describe("local action destinations", () => {
  it("maps static navigation to a real route", () => {
    expect(
      localActionHref(screen("PUB-001", "/"), runtime(), {
        id: "browse-cases",
        label: "사례 보기",
      }),
    ).toBe("/cases");
  });

  it("uses a server-owned destination for record navigation", () => {
    expect(
      localActionHref(
        screen("PUB-011", "/contracts"),
        {
          ...runtime(),
          destinations: { "open-contract": "/contracts/contract-1" },
        },
        { id: "open-contract", label: "계약 보기" },
      ),
    ).toBe("/contracts/contract-1");
  });

  it("hides a record action when an empty collection has no target", () => {
    const empty = screen("PUB-011", "/contracts");
    empty.sections = [
      {
        id: "results",
        title: "결과",
        purpose: "계약 결과",
        component: "DataCollection",
        test_id: "pub_011__section__results",
      },
    ];
    expect(
      localActionHref(empty, runtime(), {
        id: "open-contract",
        label: "계약 보기",
      }),
    ).toBeUndefined();
  });

  it("rejects protocol-relative destinations from projected data", () => {
    expect(
      localActionHref(
        screen("PUB-011", "/contracts"),
        {
          ...runtime(),
          destinations: { "open-contract": "//untrusted.example/contracts/1" },
        },
        { id: "open-contract", label: "계약 보기" },
      ),
    ).toBeUndefined();
  });

  it.each([
    [
      "CAS-002",
      "/internal/cases/case-1/overview",
      "start-next",
      "/internal/cases/case-1/signals",
    ],
    [
      "CAS-008",
      "/internal/cases/case-1/responses",
      "new-request",
      "/internal/cases/case-1/responses/new",
    ],
    [
      "CAS-014",
      "/internal/cases/case-1/preview",
      "open-review",
      "/internal/cases/case-1/review",
    ],
    [
      "SRC-002",
      "/internal/sources/source-1",
      "view-drift",
      "/internal/sources/source-1/schema-drift",
    ],
  ])("maps %s sibling navigation without duplicating route segments", (id, pathname, actionId, expected) => {
    expect(
      localActionHref(
        screen(id, pathname),
        { ...runtime(), pathname },
        { id: actionId, label: actionId },
      ),
    ).toBe(expected);
  });

  it("prioritizes a specific nested identifier over an unrelated root id", () => {
    expect(
      localActionHref(
        screen("PUB-008", "/agencies/agency-1"),
        {
          ...runtime(),
          destinations: { "view-contract": "/contracts/contract-1" },
        },
        { id: "view-contract", label: "계약 보기" },
      ),
    ).toBe("/contracts/contract-1");
  });

  it("builds existing internal detail routes from projected identifiers", () => {
    expect(
      localActionHref(
        screen("RULE-001", "/internal/rules"),
        {
          ...runtime(),
          pathname: "/internal/rules",
          destinations: { "open-rule": "/internal/rules/rule-1/versions/3" },
        },
        { id: "open-rule", label: "규칙 보기" },
      ),
    ).toBe("/internal/rules/rule-1/versions/3");
    expect(
      localActionHref(
        screen("CAS-010", "/internal/cases/case-1/agent-runs"),
        {
          ...runtime(),
          pathname: "/internal/cases/case-1/agent-runs",
          destinations: {
            "open-run": "/internal/cases/case-1/agent-runs/run-1",
          },
        },
        { id: "open-run", label: "실행 상세" },
      ),
    ).toBe("/internal/cases/case-1/agent-runs/run-1");
  });
});
