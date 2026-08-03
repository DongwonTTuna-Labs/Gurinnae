import type { ScreenViewModel } from "@gurine/ui";

export const screen = {
  id: "AUTH-001",
  title: "직원 로그인",
  route: "/auth/sign-in",
  archetype: "AUTH_SYSTEM",
  sections: [
    {
      order: 1,
      id: "environment",
      title: "환경",
      component: "StructuredContentSection",
      purpose: "production/staging 명확 표시.",
      test_id: "auth_001__section__environment",
    },
    {
      order: 2,
      id: "signin",
      title: "SSO 로그인",
      component: "StructuredContentSection",
      purpose: "OIDC 시작.",
      test_id: "auth_001__section__signin",
    },
    {
      order: 3,
      id: "support",
      title: "지원",
      component: "AccessManagementPanel",
      purpose: "계정·보안 문의.",
      test_id: "auth_001__section__support",
    },
  ],
  actions: [
    {
      id: "sign-in",
      label: "조직 계정으로 로그인",
      capability: "none",
      operation_id: "startOidcLogin",
      interaction_kind: "COMMAND",
      assurance_level: "ANONYMOUS_PROOF",
      step_up_required: false,
      confirmation_required: false,
    },
  ],
  states: [
    "loading",
    "success",
    "empty",
    "partial",
    "stale",
    "error",
    "unauthorized",
    "forbidden",
    "conflict",
  ],
  dataOperations: [
    {
      operation_id: "startOidcLogin",
      api: "identity-provider",
      method: "GET",
      path: "/auth/login",
      blocking: true,
      response_schema: "startOidcLoginReceipt",
    },
  ],
} as const satisfies ScreenViewModel;
