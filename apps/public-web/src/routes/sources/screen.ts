import type { ScreenViewModel } from "@gurine/ui";

export const screen = {
  id: "PUB-016",
  title: "데이터 출처",
  route: "/sources",
  archetype: "SEARCH_INDEX",
  sections: [
    {
      order: 1,
      id: "status",
      title: "출처 상태 요약",
      component: "StatusAndRevisionHeader",
      purpose: "healthy/stale/incident.",
      test_id: "pub_016__section__status",
    },
    {
      order: 2,
      id: "list",
      title: "출처 목록",
      component: "CoverageStatement",
      purpose: "owner·type·coverage·last sync.",
      test_id: "pub_016__section__list",
    },
    {
      order: 3,
      id: "quality",
      title: "품질 이슈",
      component: "StructuredContentSection",
      purpose: "known issues.",
      test_id: "pub_016__section__quality",
    },
    {
      order: 4,
      id: "terms",
      title: "이용 조건",
      component: "StructuredContentSection",
      purpose: "license/reuse.",
      test_id: "pub_016__section__terms",
    },
  ],
  actions: [
    {
      id: "open-source",
      label: "출처 상세",
      capability: "none",
      interaction_kind: "NAVIGATION",
      assurance_level: "NONE",
      step_up_required: false,
      confirmation_required: false,
      local_only: true,
    },
  ],
  states: ["loading", "success", "empty", "partial", "stale", "error"],
  dataOperations: [
    {
      operation_id: "listSourceStatus",
      api: "public-api",
      method: "GET",
      path: "/v1/sources/status",
      blocking: true,
      response_schema: "SourceStatusPage",
    },
  ],
} as const satisfies ScreenViewModel;
