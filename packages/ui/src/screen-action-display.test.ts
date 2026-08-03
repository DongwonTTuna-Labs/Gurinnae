import { describe, expect, it } from "vitest";
import { displayReadonlyFieldValue } from "./screen-action-display";

describe("readonly screen action display", () => {
  it("summarizes the server-bound subscription query without exposing JSON or enum tokens", () => {
    const value = JSON.stringify({
      route: "/cases",
      filters: [
        { name: "publicationState", values: ["PUBLISHED_ANOMALY"] },
        { name: "hasResponse", values: ["false"] },
      ],
      sort: "updated_desc",
    });

    expect(displayReadonlyFieldValue({ name: "query", value })).toBe(
      "공개 사례 목록 · 필터 2개 · 최근 갱신순",
    );
  });

  it("notes a search term without exposing its raw value", () => {
    const value = JSON.stringify({
      route: "/cases",
      search: "원문 검색어",
      filters: [],
      sort: "published_desc",
    });

    expect(displayReadonlyFieldValue({ name: "query", value })).toBe(
      "공개 사례 목록 · 검색어 포함 · 필터 0개 · 최근 공개순",
    );
  });

  it.each([
    "not-json",
    JSON.stringify({ route: "/cases", filters: [], sort: "raw_sort" }),
    JSON.stringify({ route: "/unknown", filters: [], sort: "updated_desc" }),
    JSON.stringify({ route: "/cases", filters: {}, sort: "updated_desc" }),
  ])("fails closed for an invalid subscription query: %s", (value) => {
    expect(displayReadonlyFieldValue({ name: "query", value })).toBe(
      "확인 필요",
    );
  });

  it("preserves existing scalar and absent-value display behavior", () => {
    expect(
      displayReadonlyFieldValue({ name: "scopeType", value: "QUERY" }),
    ).toBe("QUERY");
    expect(
      displayReadonlyFieldValue({ name: "expectedVersion", value: 4 }),
    ).toBe("4");
    expect(displayReadonlyFieldValue({ name: "consent", value: false })).toBe(
      "false",
    );
    expect(displayReadonlyFieldValue({ name: "scopeRef" })).toBe("—");
  });
});
