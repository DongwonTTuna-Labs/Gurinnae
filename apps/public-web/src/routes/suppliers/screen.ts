import type { ScreenViewModel } from "@gurine/ui";

export const screen = {
  id: "PUB-009",
  title: "업체",
  route: "/suppliers",
  archetype: "SEARCH_INDEX",
  sections: [
    {
      order: 1,
      id: "search",
      title: "업체 검색",
      component: "UnifiedSearch",
      purpose: "공식·과거 업체명과 영업·식별 상태 파셋.",
      test_id: "pub_009__section__search",
    },
    {
      order: 2,
      id: "results",
      title: "업체 목록",
      component: "DataCollection",
      purpose: "업체명·영업 상태·식별 한계·자료 범위를 포함한 업체 대장.",
      test_id: "pub_009__section__results",
    },
    {
      order: 3,
      id: "identity-note",
      title: "식별 한계",
      component: "StructuredContentSection",
      purpose: "미확정 merge를 설명.",
      test_id: "pub_009__section__identity-note",
    },
  ],
  actions: [
    {
      id: "open-supplier",
      label: "업체 보기",
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
      operation_id: "listSuppliers",
      api: "public-api",
      method: "GET",
      path: "/v1/suppliers",
      blocking: true,
      response_schema: "SuppliersPage",
    },
  ],
} as const satisfies ScreenViewModel;
