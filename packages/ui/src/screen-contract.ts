import { fieldLabel } from "./field-labels";
import { ROUTE_SCREEN_CONTRACTS } from "./generated-screen-contracts";
import { journeyForScreenId } from "./generated-screen-journeys";
import type {
  JourneyId,
  ScreenRuntime,
  ScreenViewModel,
  SemanticRegion,
  TypedScreenViewModel,
  TypedSectionViewModel,
} from "./index";

/**
 * Stable DOM id for an editable action field.
 *
 * Error summaries, focus restoration, and browser tests all use this helper
 * instead of guessing from operation names.  Keep the value human-readable so
 * it remains useful when a screen reader announces a target fragment.
 */
export function formFieldId(
  screenId: string,
  actionId: string,
  fieldName: string,
): string {
  const slug = (value: string) =>
    value
      .trim()
      .toLowerCase()
      .replace(/[^a-z0-9_-]+/gu, "-")
      .replace(/^-+|-+$/gu, "");
  return `${slug(screenId)}__field__${slug(actionId)}__${slug(fieldName)}`;
}

export const SCREEN_VIEW_MODEL_REGISTRY = Object.freeze({
  response: {
    prefix: "RSP-",
    journey: "J-03" as const,
    persona: "소명 대상자",
  },
  public: {
    prefix: "PUB-",
    journey: "J-01" as const,
    persona: "공개 독자·연구자",
  },
  signal: {
    prefix: "SIG-",
    journey: "J-05" as const,
    persona: "신호 분류 담당자",
  },
  review: { prefix: "REV-", journey: "J-07" as const, persona: "독립 검토자" },
  research: {
    prefix: "CAS-01",
    journey: "J-10" as const,
    persona: "조사 담당자",
  },
  commercial: {
    prefix: "OPS-004",
    journey: "J-12" as const,
    persona: "조직 운영자",
  },
  action: {
    prefix: "INT-002",
    journey: "J-11" as const,
    persona: "승인 담당자",
  },
});

const journeyFor = (screen: ScreenViewModel): JourneyId => {
  const resolved = journeyForScreenId(screen.id);
  if (screen.journey && screen.journey !== resolved) {
    throw new Error(
      `screen journey mismatch: ${screen.id} expected ${resolved}, received ${screen.journey}`,
    );
  }
  return resolved;
};

function personaFor(journey: JourneyId): string {
  if (journey === "J-03") return SCREEN_VIEW_MODEL_REGISTRY.response.persona;
  if (journey === "J-05") return SCREEN_VIEW_MODEL_REGISTRY.signal.persona;
  if (journey === "J-07") return SCREEN_VIEW_MODEL_REGISTRY.review.persona;
  if (journey === "J-10") return SCREEN_VIEW_MODEL_REGISTRY.research.persona;
  if (journey === "J-11") return SCREEN_VIEW_MODEL_REGISTRY.action.persona;
  if (journey === "J-12") return SCREEN_VIEW_MODEL_REGISTRY.commercial.persona;
  if (journey === "J-01") return SCREEN_VIEW_MODEL_REGISTRY.public.persona;
  return "조사 담당자";
}

const regionFor = (
  id: string,
  section: string,
  index: number,
): SemanticRegion => {
  const token = `${id}:${section}`.toLowerCase();
  if (/(identity|object|subject|header|overview|summary)/.test(token))
    return "identity";
  if (/(state|status|progress|receipt|timeline|revision|deadline)/.test(token))
    return "state";
  if (/(unknown|counter|dispute|blocker|risk|security)/.test(token))
    return "unknowns";
  if (/(evidence|source|reference|citation|attachment|files)/.test(token))
    return "evidence";
  if (/(next|action|process|save|submit|request|handoff)/.test(token))
    return "next-action";
  if (/(review|decision|publish|consent|authority)/.test(token))
    return "review";
  if (/(triage|signal|duplicate|queue)/.test(token)) return "triage";
  if (/(agent|analysis|run|suggestion|promotion)/.test(token))
    return "analysis";
  if (/(budget|cost|commercial|revenue|health|retention)/.test(token))
    return "commercial";
  return index === 0 ? "priority" : "state";
};

const normalizeRegion = (
  region: string,
  fallback: SemanticRegion,
): SemanticRegion =>
  (
    ({
      object: "identity",
      answer: "priority",
      next_action: "next-action",
      "next-action": "next-action",
      unknown: "unknowns",
      state: "state",
      evidence: "evidence",
      review: "review",
      triage: "triage",
      approval: "approval",
      analysis: "analysis",
      commercial: "commercial",
    }) satisfies Record<string, SemanticRegion>
  )[region] ?? fallback;

const stateProfile = (screen: ScreenViewModel): ScreenRuntime["state"][] => {
  const states = Array.isArray(screen.states)
    ? screen.states.filter(
        (value): value is string => typeof value === "string",
      )
    : [];
  const allowed = new Set<ScreenRuntime["state"]>([
    "loading",
    "initial-loading",
    "success",
    "empty",
    "filtered-empty",
    "partial",
    "stale",
    "error",
    "server-error",
    "not-found",
    "unauthenticated",
    "forbidden",
    "unauthorized",
    "conflict",
    "receipt",
    "offline",
    "saving",
    "saved",
    "current",
    "draft",
    "superseded",
    "healthy",
    "maintenance",
    "invalid-filter",
    "validation-error",
    "session-expiring",
    "session-expired",
    "blocked",
    "refreshing",
    "degraded",
    "incident",
    "telemetry-gap",
    "ready",
    "reauth-required",
    "submitting",
    "partial-failure",
    "terminal",
  ]);
  const normalized = states.filter((value): value is ScreenRuntime["state"] =>
    allowed.has(value as ScreenRuntime["state"]),
  );
  return normalized.length > 0
    ? normalized
    : [
        "loading",
        "success",
        "empty",
        "partial",
        "stale",
        "error",
        "unauthorized",
        "forbidden",
        "conflict",
      ];
};

/** Converts an authority route declaration into a stable, semantic screen VM. */
export function typedScreenViewModel(
  screen: ScreenViewModel,
): TypedScreenViewModel {
  if (screen.contract) return screen.contract;
  const journey = journeyFor(screen);
  const routeContract =
    ROUTE_SCREEN_CONTRACTS[screen.id as keyof typeof ROUTE_SCREEN_CONTRACTS];
  if (!routeContract)
    throw new Error(`typed screen contract missing: ${screen.id}`);
  const sections: TypedSectionViewModel[] = screen.sections.map(
    (section, index) => {
      const declared = routeContract.sections.find(
        (item) => item.id === section.id,
      );
      // Unit fixtures use a deliberately synthetic /test route. Keep that
      // fixture path deterministic without weakening production route closure.
      if (!declared && screen.route === "/test") {
        return {
          id: section.id,
          title: section.title,
          purpose: section.purpose,
          region: index === 0 ? "identity" : "state",
          component: section.component,
          testId: section.test_id,
          order: index + 1,
          fields: [`${screen.id.toLowerCase()}.${section.id}`],
        };
      }
      if (!declared)
        throw new Error(
          `typed section contract missing: ${screen.id}.${section.id}`,
        );
      if (
        screen.route !== "/test" &&
        declared.component &&
        section.component !== declared.component
      ) {
        throw new Error(
          `screen component contract mismatch: ${screen.id}.${section.id} expected ${declared.component}, received ${section.component}`,
        );
      }
      return {
        id: section.id,
        title: section.title,
        purpose: section.purpose,
        region: normalizeRegion(
          String(declared.region),
          regionFor(screen.id, section.id, index),
        ),
        component: section.component,
        authorityComponent: declared.component,
        testId: section.test_id,
        order: index + 1,
        fields: declared.fields,
      };
    },
  );
  const primary =
    screen.route === "/test"
      ? (screen.actions.find((action) => action.primary === true) ??
        screen.actions[0])
      : (screen.actions.find(
          (action) => action.id === routeContract.primaryActionId,
        ) ??
        screen.actions.find((action) => action.primary === true) ??
        screen.actions[0]);
  return {
    screenId: screen.id,
    journey,
    objectLabel: routeContract.objectLabel || screen.title,
    persona: routeContract.persona || personaFor(journey),
    answerFirst:
      sections[0]?.purpose ??
      `${screen.title}의 현재 상태와 다음 작업을 확인합니다.`,
    sections,
    states: stateProfile(screen),
    primaryActionId:
      screen.route === "/test"
        ? (primary?.id ?? null)
        : (routeContract.primaryActionId ?? primary?.id ?? null),
    primaryActionLabel:
      screen.route === "/test"
        ? typeof primary?.label === "string"
          ? primary.label
          : null
        : (routeContract.primaryActionLabel ??
          (typeof primary?.label === "string" ? primary.label : null)),
    requiresDecisionReason:
      journey === "J-07" || journey === "J-11" || screen.id === "SIG-002",
    showsReceipt:
      journey === "J-03" ||
      journey === "J-10" ||
      journey === "J-11" ||
      journey === "J-12",
  };
}

/**
 * Normalize a server route declaration to the canonical manifest component
 * before validation/rendering.  The effective overlay may carry a surface
 * compatibility component, but the runtime DOM must expose the authority
 * component from the closed route registry.
 */
export function canonicalizeScreenViewModel(
  screen: ScreenViewModel,
): ScreenViewModel {
  if (screen.route === "/test") return screen;
  const routeContract =
    ROUTE_SCREEN_CONTRACTS[screen.id as keyof typeof ROUTE_SCREEN_CONTRACTS];
  if (!routeContract) return screen;
  for (const section of screen.sections) {
    const declared = routeContract.sections.find(
      (item) => item.id === section.id,
    );
    if (!declared) {
      throw new Error(
        `screen section contract missing: ${screen.id}.${section.id}`,
      );
    }
    if (declared.component !== section.component) {
      throw new Error(
        `screen component contract mismatch: ${screen.id}.${section.id} expected ${declared.component}, received ${section.component}`,
      );
    }
  }
  return screen;
}

export const stateLabel = (state: ScreenRuntime["state"]): string =>
  ({
    loading: "불러오는 중",
    "initial-loading": "처음 불러오는 중",
    success: "최신 상태",
    empty: "자료 없음",
    "filtered-empty": "조건에 맞는 자료 없음",
    partial: "일부만 확인됨",
    stale: "갱신 필요",
    error: "오류",
    "server-error": "서버 오류",
    "not-found": "자료를 찾을 수 없음",
    unauthenticated: "로그인 필요",
    unauthorized: "접근 불가",
    forbidden: "권한 없음",
    conflict: "변경 충돌",
    receipt: "영수증 확인됨",
    offline: "오프라인",
    saving: "저장 중",
    saved: "저장됨",
    current: "현재 버전",
    draft: "초안",
    superseded: "새 버전으로 대체됨",
    healthy: "정상 운영",
    maintenance: "점검 중",
    "invalid-filter": "필터 확인 필요",
    "validation-error": "입력 확인 필요",
    "session-expiring": "세션 만료 임박",
    "session-expired": "세션 만료",
    blocked: "진행 차단됨",
    refreshing: "갱신 중",
    degraded: "일부 기능 제한",
    incident: "장애 대응 중",
    "telemetry-gap": "관측 공백",
    ready: "작업 가능",
    "reauth-required": "재인증 필요",
    submitting: "제출 중",
    "partial-failure": "일부 처리 불확실",
    terminal: "종료됨",
  })[state];

export const humanFieldLabel = fieldLabel;
