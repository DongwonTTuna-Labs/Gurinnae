import type { ScreenViewModel } from "@gurine/ui";

export const screen = {
  id: "PUB-007",
  title: "기관",
  route: "/agencies",
  archetype: "SEARCH_INDEX",
  sections: [
    {
      order: 1,
      id: "search",
      title: "기관 검색",
      component: "UnifiedSearch",
      purpose: "공식·과거 기관명과 기관 유형·관할 파셋.",
      test_id: "pub_007__section__search",
    },
    {
      order: 2,
      id: "results",
      title: "기관 목록",
      component: "DataCollection",
      purpose: "기관명·유형·관할·자료 범위를 포함한 기관 대장.",
      test_id: "pub_007__section__results",
    },
    {
      order: 3,
      id: "coverage",
      title: "수집 범위",
      component: "CoverageStatement",
      purpose: "미포함 기관 설명.",
      test_id: "pub_007__section__coverage",
    },
  ],
  actions: [
    {
      id: "open-agency",
      label: "기관 보기",
      capability: "none",
      interaction_kind: "NAVIGATION",
      assurance_level: "NONE",
      step_up_required: false,
      confirmation_required: false,
      local_only: true,
    },
    {
      id: "apply-filter",
      label: "필터 적용",
      capability: "none",
      local_only: true,
      persistence: "url",
      interaction_kind: "COMMAND",
      assurance_level: "NONE",
      step_up_required: false,
      confirmation_required: false,
    },
  ],
  states: ["loading", "success", "empty", "partial", "stale", "error"],
  dataOperations: [
    {
      operation_id: "listAgencies",
      api: "public-api",
      method: "GET",
      path: "/v1/agencies",
      blocking: true,
      response_schema: "AgenciesPage",
    },
  ],
} as const satisfies ScreenViewModel;
