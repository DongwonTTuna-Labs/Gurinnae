import type { ScreenViewModel } from "@gurine/ui";
import type { RequestEvent } from "@sveltejs/kit";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { screen as agencyScreen } from "../../routes/agencies/[agencySlug]/screen";
import { screen as caseDetailScreen } from "../../routes/cases/[caseSlug]/screen";
import { screen as caseLedgerScreen } from "../../routes/cases/screen";
import { screen as correctionsScreen } from "../../routes/corrections/screen";
import { screen as dataScreen } from "../../routes/data/screen";
import { screen as homeScreen } from "../../routes/screen";
import { screen as searchScreen } from "../../routes/search/screen";
import { screen as subscribeScreen } from "../../routes/subscribe/screen";
import { screen as supplierScreen } from "../../routes/suppliers/[supplierSlug]/screen";
import { requestLocale } from "./screen-helpers";
import {
  INVALID_REQUIRED_SEARCH_CONDITIONS_MESSAGE,
  loadScreen,
  publicInitialLoadPlan,
  publicScreenDestinations,
} from "./screen-load";

const invokePublicOperation = vi.hoisted(() => vi.fn());
const privateEnv = vi.hoisted(() => ({
  BOT_CHALLENGE_SITE_KEY: "synthetic-test",
  PUBLIC_API_INTERNAL_URL: "http://public-api.test",
}));

vi.mock("@gurine/api-client-public", () => ({ invokePublicOperation }));
vi.mock("$env/dynamic/private", () => ({ env: privateEnv }));

function requestEvent(
  path: string,
  options: {
    headers?: HeadersInit;
    params?: Record<string, string>;
  } = {},
): RequestEvent {
  const url = new URL(path, "http://public-web.test");
  return {
    cookies: { get: () => undefined },
    fetch: globalThis.fetch,
    params: options.params ?? {},
    request: new Request(url, {
      ...(options.headers ? { headers: options.headers } : {}),
    }),
    url,
  } as unknown as RequestEvent;
}

function emptyPage() {
  return {
    data: {
      appliedFilters: {},
      asOf: "2026-07-30T00:00:00Z",
      items: [],
    },
    error: undefined,
    response: new Response(null, { status: 200 }),
  };
}

beforeEach(() => {
  invokePublicOperation.mockReset();
  invokePublicOperation.mockResolvedValue(emptyPage());
});

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

describe("PUB-004 correction destination", () => {
  it("binds the current case and its validated authority revision", () => {
    expect(
      publicScreenDestinations(caseDetailScreen, "/cases/case-a", {
        getPublicCase: { slug: "case-a", revision: 7 },
      }),
    ).toMatchObject({
      "request-correction": "/correction-request?case=case-a&revision=7",
    });
  });

  it.each([
    ["missing response", undefined],
    ["missing revision", { slug: "case-a" }],
    ["invalid revision", { slug: "case-a", revision: 0 }],
    ["mismatched case", { slug: "case-b", revision: 7 }],
  ])("omits the action for %s", (_label, getPublicCase) => {
    const destinations = publicScreenDestinations(
      caseDetailScreen,
      "/cases/case-a",
      getPublicCase === undefined ? {} : { getPublicCase },
    );
    expect(destinations).not.toHaveProperty("request-correction");
  });
});

describe("contextual subscription destinations", () => {
  it("binds the cursor-free public case filter snapshot", () => {
    const params = new URLSearchParams({
      publicationState: "PUBLISHED_EXPLAINED",
      agencyId: "agency-a",
      sort: "published_desc",
      cursor: "must-not-survive",
      internalNote: "must-not-survive",
    });
    const destination = publicScreenDestinations(
      caseLedgerScreen,
      "/cases",
      {},
      params,
    )["subscribe-filter"];
    expect(destination).toBeDefined();
    const url = new URL(destination ?? "", "http://public-web.test");
    expect(url.pathname).toBe("/subscribe");
    expect(url.searchParams.get("scope")).toBe("QUERY");
    expect(JSON.parse(url.searchParams.get("query") ?? "null")).toEqual({
      route: "/cases",
      filters: [
        { name: "agencyId", values: ["agency-a"] },
        {
          name: "publicationState",
          values: ["PUBLISHED_EXPLAINED"],
        },
      ],
      sort: "published_desc",
    });
  });

  it.each([
    [
      caseDetailScreen,
      "/cases/case-a",
      "subscribe-case",
      "/subscribe?scope=CASE&ref=case-a&returnTo=%2Fcases%2Fcase-a",
    ],
    [
      agencyScreen,
      "/agencies/agency-a",
      "subscribe-agency",
      "/subscribe?scope=AGENCY&ref=agency-a",
    ],
    [
      supplierScreen,
      "/suppliers/supplier-a",
      "subscribe-supplier",
      "/subscribe?scope=SUPPLIER&ref=supplier-a",
    ],
    [
      correctionsScreen,
      "/corrections",
      "subscribe",
      "/subscribe?scope=CORRECTIONS",
    ],
  ])("binds %s to a validated contextual subscription", (screen, pathname, actionId, expected) => {
    expect(publicScreenDestinations(screen, pathname, {})[actionId]).toBe(
      expected,
    );
  });

  it("omits a record subscription when its route context is invalid", () => {
    expect(
      publicScreenDestinations(caseDetailScreen, "/cases/../internal", {}),
    ).not.toHaveProperty("subscribe-case");
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

describe("public initial loads", () => {
  it("loads PUB-001 with the recent-public default and without search", async () => {
    expect(
      homeScreen.dataOperations.map(({ operation_id }) => operation_id),
    ).toEqual(["listPublicCases", "listCorrections", "listSourceStatus"]);

    const { runtime } = await loadScreen(requestEvent("/"), homeScreen);

    expect(invokePublicOperation).toHaveBeenCalledTimes(3);
    expect(invokePublicOperation).toHaveBeenCalledWith(
      expect.objectContaining({
        operationId: "listPublicCases",
        query: { sort: "published_desc" },
      }),
    );
    expect(invokePublicOperation).not.toHaveBeenCalledWith(
      expect.objectContaining({ operationId: "searchPublicRecords" }),
    );
    expect(runtime.errors).toEqual([]);
  });

  it("uses a caller-supplied valid PUB-001 sort instead of the default", () => {
    expect(
      publicInitialLoadPlan(
        "PUB-001",
        "listPublicCases",
        [{ name: "sort", in: "query" }],
        new URLSearchParams("sort=updated_desc"),
      ),
    ).toEqual({ kind: "request", query: { sort: "updated_desc" } });
  });

  it("enforces the PUB-002 signals.query_present request boundary at runtime", async () => {
    for (const path of ["/search", "/search?q=", "/search?q=%20%20"]) {
      invokePublicOperation.mockClear();
      const { runtime } = await loadScreen(requestEvent(path), searchScreen);

      expect(invokePublicOperation).not.toHaveBeenCalled();
      expect(runtime.state).toBe("awaiting-query");
      expect(runtime.errors).toEqual([]);
    }

    invokePublicOperation.mockClear();
    const { runtime } = await loadScreen(
      requestEvent("/search?q=%EA%B3%84%EC%95%BD"),
      searchScreen,
    );

    expect(invokePublicOperation).toHaveBeenCalledTimes(1);
    expect(invokePublicOperation).toHaveBeenCalledWith(
      expect.objectContaining({
        operationId: "searchPublicRecords",
        query: { q: "계약" },
      }),
    );
    expect(runtime.state).toBe("empty");
    expect(runtime.errors).toEqual([]);
    expect(runtime.publicLedger).toMatchObject({
      screenId: "PUB-002",
      rows: [],
    });
  });

  it("fails closed when a public list response has an undeclared field", async () => {
    invokePublicOperation.mockResolvedValueOnce({
      ...emptyPage(),
      data: { ...emptyPage().data, internalNote: "must-not-leak" },
    });

    const { runtime } = await loadScreen(
      requestEvent("/search?q=%EA%B3%84%EC%95%BD"),
      searchScreen,
    );

    expect(runtime.state).toBe("error");
    expect(runtime.publicLedger).toBeUndefined();
    expect(runtime.errors).toContain(
      "공개 목록 응답 형식이 올바르지 않습니다.",
    );
  });
});

describe("public form presentation inputs", () => {
  it("selects a canonical locale from Accept-Language and rejects invalid ranges", () => {
    expect(
      requestLocale(
        new Request("http://public-web.test", {
          headers: { "accept-language": "ko-kr, en-US;q=0.8" },
        }),
      ),
    ).toBe("ko-KR");
    expect(
      requestLocale(
        new Request("http://public-web.test", {
          headers: { "accept-language": "*, invalid_locale" },
        }),
      ),
    ).toBe("ko-KR");
  });

  it("supplies a readonly locale from Accept-Language to PUB-029", async () => {
    const { runtime } = await loadScreen(
      requestEvent("/subscribe", {
        headers: { "accept-language": "ko-KR, en-US;q=0.8" },
      }),
      subscribeScreen,
    );

    expect(
      runtime.forms["request-verification"]?.find(
        (field) => field.name === "locale",
      ),
    ).toMatchObject({ value: "ko-KR", readonly: true });
  });

  it("reduces a nonempty generated dataset response to dataset cards", async () => {
    invokePublicOperation.mockResolvedValueOnce({
      data: {
        items: [
          {
            id: "public-cases",
            title: "공개 사건 데이터",
            description: "공개 사건과 개정 이력",
            format: "CSV, JSONL",
            coverage: {
              dateRange: { label: "2026년" },
              sourceIds: [],
              recordCount: 8,
              knownGaps: [],
              freshness: {
                asOf: "2026-07-30T00:00:00Z",
                status: "CURRENT",
              },
            },
            license: "공개 이용",
            updatedAt: "2026-07-30T00:00:00Z",
            downloadUrl: "/downloads/public-cases",
          },
        ],
        appliedFilters: {},
        asOf: "2026-07-30T00:00:00Z",
      },
      error: undefined,
      response: new Response(null, { status: 200 }),
    });

    const { runtime } = await loadScreen(requestEvent("/data"), dataScreen);

    expect(runtime.publicDatasets).toEqual([
      {
        id: "public-cases",
        title: "공개 사건 데이터",
        description: "공개 사건과 개정 이력",
        format: "CSV, JSONL",
        license: "공개 이용",
        updatedAt: "2026-07-30T00:00:00Z",
      },
    ]);
    expect(runtime.data).toEqual({});
  });
});
