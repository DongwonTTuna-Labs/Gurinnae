import type { ScreenViewModel } from "@gurine/ui";
import { describe, expect, it } from "vitest";
import {
  INVALID_REQUIRED_SEARCH_CONDITIONS_MESSAGE,
  publicScreenDestinations,
} from "./screen-load";

const sourceScreen: ScreenViewModel = {
  id: "PUB-017",
  title: "데이터 출처 상세",
  route: "/sources/{sourceId}",
  archetype: "ENTITY_DETAIL",
  sections: [],
  actions: [
    {
      id: "view-official",
      label: "공식 출처 열기",
      interaction_kind: "EXTERNAL_LINK",
      local_only: true,
    },
    {
      id: "view-related-rules",
      label: "관련 규칙",
      interaction_kind: "NAVIGATION",
      local_only: true,
    },
  ],
  states: [],
  dataOperations: [],
};

function sourceResponse(officialUrl: unknown): Record<string, unknown> {
  return {
    getSource: {
      data: { officialUrl, rawDtoField: "must-not-leak" },
      links: [{ href: "must-not-leak" }],
      rawDtoField: "must-not-leak",
    },
  };
}

describe("PUB-017 official source destination", () => {
  it.each([
    "https://www.data.go.kr/",
    "http://records.example/source",
  ])("exposes a validated %s destination without the response DTO", (officialUrl) => {
    expect(
      publicScreenDestinations(
        sourceScreen,
        "/sources/source-1",
        sourceResponse(officialUrl),
      ),
    ).toEqual({
      "view-official": officialUrl,
      "view-related-rules": "/methodology",
    });
  });

  it.each([
    null,
    "",
    " https://www.data.go.kr/",
    "https://www.data.go.kr/ ",
    "not-a-url",
    "//www.data.go.kr/",
    "ftp://www.data.go.kr/source",
    "javascript:alert(1)",
    42,
    {},
  ])("omits an invalid destination value %j", (officialUrl) => {
    expect(
      publicScreenDestinations(
        sourceScreen,
        "/sources/source-1",
        sourceResponse(officialUrl),
      ),
    ).toEqual({ "view-related-rules": "/methodology" });
  });
});

describe("public search validation message", () => {
  it("does not expose the raw operation identifier", () => {
    expect(INVALID_REQUIRED_SEARCH_CONDITIONS_MESSAGE).toBe(
      "필수 검색 조건이 올바르지 않습니다.",
    );
    expect(INVALID_REQUIRED_SEARCH_CONDITIONS_MESSAGE).not.toContain(
      "searchPublicRecords",
    );
  });
});
