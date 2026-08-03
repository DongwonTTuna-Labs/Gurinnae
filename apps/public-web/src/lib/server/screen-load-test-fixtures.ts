import type { ScreenViewModel } from "@gurine/ui";
import type { RequestEvent } from "@sveltejs/kit";
import { PUBLIC_EMPTY_RESULT_NOTICE } from "./public-presentation-schemas";

export function requestEvent(
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

export function emptyPage(
  description = PUBLIC_EMPTY_RESULT_NOTICE,
  canonicalUrl = "/search",
) {
  return {
    data: {
      appliedFilters: {},
      asOf: "2026-07-30T00:00:00Z",
      items: [],
      seo: {
        title: "공개 기록 · 구린네",
        description,
        openGraphDescription: description,
        canonicalUrl,
        robots: "index,follow",
      },
    },
    error: undefined,
    response: new Response(null, { status: 200 }),
  };
}

export const sourceScreen: ScreenViewModel = {
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

export function sourceResponse(officialUrl: unknown): Record<string, unknown> {
  return {
    getSource: {
      data: { officialUrl, rawDtoField: "must-not-leak" },
      links: [{ href: "must-not-leak" }],
      rawDtoField: "must-not-leak",
    },
  };
}
