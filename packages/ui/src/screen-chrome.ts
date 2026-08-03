import type {
  ScreenRuntime,
  ScreenViewModel,
  TypedScreenViewModel,
} from "./index";
import { formFieldId } from "./screen-contract";

export type ScreenSurface = "public" | "response" | "auth" | "internal";
export type StateTone =
  | "neutral"
  | "info"
  | "status"
  | "caution"
  | "status-alert";
export type BreadcrumbItem = { label: string; href: string };
export type ResponseProgressState =
  | "not-started"
  | "in-progress"
  | "complete"
  | "error";
export type CaseTaskLink = { label: string; href: string };

const BREADCRUMB_LABELS: Readonly<Record<string, string>> = {
  about: "소개",
  admin: "관리",
  agencies: "기관",
  "agent-runs": "에이전트 실행",
  audit: "감사",
  auth: "인증",
  cases: "사례",
  claims: "주장",
  contracts: "계약",
  "correction-request": "정정 요청",
  corrections: "정정",
  evidence: "근거",
  hypotheses: "가설",
  internal: "내부",
  jobs: "작업",
  methodology: "방법론",
  operations: "운영",
  preview: "미리보기",
  respond: "응답",
  responses: "응답",
  review: "검토",
  revisions: "개정판",
  rules: "규칙",
  runs: "실행",
  signals: "신호",
  sources: "출처",
  subscription: "업데이트 구독",
  suppliers: "업체",
  users: "사용자",
  versions: "버전",
};
const ROUTE_PARAMETER_SEGMENT = /^\{[^{}]+\}$/;

const BUSY_STATES: readonly ScreenRuntime["state"][] = [
  "loading",
  "initial-loading",
  "refreshing",
  "saving",
  "submitting",
];
const ALERT_STATES: readonly ScreenRuntime["state"][] = [
  "error",
  "server-error",
  "forbidden",
  "unauthorized",
  "conflict",
  "partial-failure",
  "incident",
  "unauthenticated",
];
const CAUTION_STATES: readonly ScreenRuntime["state"][] = [
  "stale",
  "partial",
  "offline",
  "maintenance",
  "invalid-filter",
  "validation-error",
  "session-expiring",
  "session-expired",
  "blocked",
  "degraded",
  "telemetry-gap",
  "reauth-required",
];
const STATUS_STATES: readonly ScreenRuntime["state"][] = [
  "success",
  "saved",
  "current",
  "healthy",
  "ready",
  "receipt",
  "terminal",
];
const STALE_CONTEXT_STATES: readonly ScreenRuntime["state"][] = [
  "stale",
  "partial",
  "offline",
  "degraded",
  "telemetry-gap",
  "maintenance",
];

export function surfaceForScreen(screenId: string): ScreenSurface {
  if (screenId.startsWith("PUB-")) return "public";
  if (screenId.startsWith("RSP-")) return "response";
  if (screenId.startsWith("AUTH-")) return "auth";
  return "internal";
}

export function isBusyState(state: ScreenRuntime["state"]): boolean {
  return BUSY_STATES.includes(state);
}

export function isWorkspaceScreen(
  screen: ScreenViewModel,
  pathname: string,
): boolean {
  return (
    screen.archetype === "WORKSPACE" ||
    screen.id === "INT-002" ||
    pathname.startsWith("/internal/cases/")
  );
}

export function primaryActionAllowed(
  contract: TypedScreenViewModel,
  runtime: ScreenRuntime,
): boolean {
  return (
    contract.primaryActionId !== null &&
    (!runtime.allowedActionIds ||
      runtime.allowedActionIds.includes(contract.primaryActionId))
  );
}

export function primaryTargetForAction(actionId: string | null): string {
  return actionId ? `#action-${actionId}` : "#page-actions";
}

export function statusSectionIdForScreen(
  sections: ScreenViewModel["sections"],
): "status" | null {
  return sections.some((section) => section.id === "status") ? "status" : null;
}

export function sourceSectionForId(
  screen: ScreenViewModel,
  sectionId: string,
): ScreenViewModel["sections"][number] {
  const source = screen.sections.find((section) => section.id === sectionId);
  if (!source)
    throw new Error(
      `screen section contract missing: ${screen.id}.${sectionId}`,
    );
  return source;
}

export function breadcrumbItemsForScreen(
  screen: ScreenViewModel,
  pathname: string | undefined,
): readonly BreadcrumbItem[] {
  const path = pathname ?? screen.route;
  if (path === "/" || screen.id === "PUB-001") return [];
  const segments = path.split("/").filter(Boolean);
  const routeSegments = screen.route.split("/").filter(Boolean);
  const items: BreadcrumbItem[] = [{ label: "홈", href: "/" }];
  let href = "";
  for (const [index, segment] of segments.slice(0, -1).entries()) {
    href += `/${segment}`;
    const routeSegment = routeSegments[index];
    if (routeSegment && ROUTE_PARAMETER_SEGMENT.test(routeSegment)) {
      items.push({ label: segment, href });
      continue;
    }
    const label = Object.hasOwn(BREADCRUMB_LABELS, segment)
      ? BREADCRUMB_LABELS[segment]
      : undefined;
    if (!label) {
      throw new Error(
        `breadcrumb label missing for static route segment: ${segment}`,
      );
    }
    items.push({ label, href });
  }
  items.push({ label: screen.title, href: path });
  return items;
}

export function responseStepForScreen(screenId: string): number {
  const steps: Record<string, number> = {
    "RSP-002": 1,
    "RSP-003": 2,
    "RSP-004": 3,
    "RSP-005": 4,
    "RSP-006": 5,
    "RSP-007": 2,
    "RSP-008": 0,
  };
  return steps[screenId] ?? 1;
}

export function responseProgressStateForStep(
  step: number,
  responseStep: number,
  errorCount: number,
): ResponseProgressState {
  if (errorCount > 0) return "error";
  if (step < responseStep) return "complete";
  if (step === responseStep) return "in-progress";
  return "not-started";
}

export function errorTargetForMessage(
  screen: ScreenViewModel,
  runtime: ScreenRuntime,
  message: string,
): string | null {
  const haystack = message.toLocaleLowerCase();
  for (const action of screen.actions) {
    for (const field of runtime.forms[action.id] ?? []) {
      if (field.readonly) continue;
      const tokens = [field.name, field.label]
        .filter(Boolean)
        .map((token) => token.toLocaleLowerCase());
      if (tokens.some((token) => haystack.includes(token))) {
        const base = formFieldId(screen.id, action.id, field.name);
        if (field.name === "answers") return `${base}-answer-1`;
        if (field.name.toLowerCase().includes("consent"))
          return `${base}-body-consent`;
        return base;
      }
    }
  }
  return null;
}

export function stateTone(state: ScreenRuntime["state"]): StateTone {
  if (ALERT_STATES.includes(state)) return "status-alert";
  if (CAUTION_STATES.includes(state)) return "caution";
  if (STATUS_STATES.includes(state)) return "status";
  return "neutral";
}

export function caseTaskLinksForPath(
  pathname: string,
): readonly CaseTaskLink[] {
  const match = pathname.match(/^\/internal\/cases\/([^/]+)/);
  if (!match?.[1]) return [];
  const prefix = `/internal/cases/${match[1]}`;
  return [
    { label: "개요", href: `${prefix}/overview` },
    { label: "증거", href: `${prefix}/evidence` },
    { label: "주장", href: `${prefix}/claims` },
    { label: "가설", href: `${prefix}/hypotheses` },
    { label: "검토", href: `${prefix}/review` },
    { label: "미리보기", href: `${prefix}/preview` },
    { label: "정정", href: `${prefix}/corrections` },
    { label: "감사", href: `${prefix}/audit` },
    { label: "에이전트 실행", href: `${prefix}/agent-runs` },
    { label: "응답", href: `${prefix}/responses` },
    { label: "타임라인", href: `${prefix}/timeline` },
  ];
}

export function contextBlockerMessage(
  state: ScreenRuntime["state"],
  errorCount: number,
): string {
  if (
    state === "unauthenticated" ||
    state === "unauthorized" ||
    state === "forbidden"
  )
    return "접근 권한을 확인한 뒤 다음 행동을 진행하세요.";
  if (errorCount > 0) return "오류 원인을 확인하고 다시 시도하세요.";
  if (STALE_CONTEXT_STATES.includes(state))
    return "자료가 최신이 아니거나 일부만 확인되었으므로 결정 전에 기준 시각과 미확인 범위를 확인하세요.";
  return "서버가 최신 상태·권한·버전을 확인했습니다.";
}
