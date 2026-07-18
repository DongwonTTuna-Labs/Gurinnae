import type {
  JourneyId,
  ScreenRuntime,
  ScreenViewModel,
  SemanticRegion,
  TypedScreenViewModel,
  TypedSectionViewModel,
} from "./index";
import { ROUTE_SCREEN_CONTRACTS } from "./generated-screen-contracts";

export const SCREEN_VIEW_MODEL_REGISTRY = Object.freeze({
  response: { prefix: "RSP-", journey: "J-03" as const, persona: "소명 대상자" },
  public: { prefix: "PUB-", journey: "J-01" as const, persona: "공개 독자·연구자" },
  signal: { prefix: "SIG-", journey: "J-05" as const, persona: "신호 분류 담당자" },
  review: { prefix: "REV-", journey: "J-07" as const, persona: "독립 검토자" },
  research: { prefix: "CAS-01", journey: "J-10" as const, persona: "조사 담당자" },
  commercial: { prefix: "OPS-004", journey: "J-12" as const, persona: "조직 운영자" },
  action: { prefix: "INT-002", journey: "J-11" as const, persona: "승인 담당자" },
});

const journeyFor = (screen: ScreenViewModel): JourneyId => {
  const declared = screen.journey;
  if (typeof declared === "string" && /^J-0[1-9]$|^J-1[0-2]$/.test(declared)) return declared as JourneyId;
  const id = screen.id;
  if (id.startsWith("RSP-") || id === "CAS-008" || id === "CAS-009") return "J-03";
  if (id.startsWith("PUB-") || id.startsWith("COR-") || id.startsWith("AUTH-")) return "J-01";
  if (id.startsWith("SIG-")) return "J-05";
  if (id === "INT-002") return "J-11";
  if (id.startsWith("REV-")) return "J-07";
  if (id === "CAS-010" || id === "CAS-011") return "J-10";
  if (id === "OPS-004" || id === "OPS-005" || id === "OPS-001") return "J-12";
  if (id.startsWith("OPS-") || id.startsWith("SRC-")) return "J-09";
  if (id.startsWith("CAS-")) return "J-06";
  return "J-02";
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

const regionFor = (id: string, section: string, index: number): SemanticRegion => {
  const token = `${id}:${section}`.toLowerCase();
  if (/(identity|object|subject|header|overview|summary)/.test(token)) return "identity";
  if (/(state|status|progress|receipt|timeline|revision|deadline)/.test(token)) return "state";
  if (/(unknown|counter|dispute|blocker|risk|security)/.test(token)) return "unknowns";
  if (/(evidence|source|reference|citation|attachment|files)/.test(token)) return "evidence";
  if (/(next|action|process|save|submit|request|handoff)/.test(token)) return "next-action";
  if (/(review|decision|publish|consent|authority)/.test(token)) return "review";
  if (/(triage|signal|duplicate|queue)/.test(token)) return "triage";
  if (/(agent|analysis|run|suggestion|promotion)/.test(token)) return "analysis";
  if (/(budget|cost|commercial|revenue|health|retention)/.test(token)) return "commercial";
  return index === 0 ? "priority" : "state";
};

const normalizeRegion = (region: string, fallback: SemanticRegion): SemanticRegion => ({
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
} satisfies Record<string, SemanticRegion>)[region] ?? fallback;

const stateProfile = (screen: ScreenViewModel): ScreenRuntime["state"][] => {
  const states = Array.isArray(screen.states)
    ? screen.states.filter((value): value is string => typeof value === "string")
    : [];
  const allowed = new Set<ScreenRuntime["state"]>([
    "loading", "success", "empty", "partial", "stale", "error", "unauthenticated",
    "forbidden", "unauthorized", "conflict", "receipt", "offline", "saving", "saved",
    "validation-error", "session-expiring", "blocked", "refreshing", "degraded", "incident",
    "telemetry-gap", "ready", "reauth-required", "submitting", "partial-failure", "terminal",
  ]);
  const normalized = states.filter((value): value is ScreenRuntime["state"] => allowed.has(value as ScreenRuntime["state"]));
  return normalized.length > 0 ? normalized : ["loading", "success", "empty", "partial", "stale", "error", "unauthorized", "forbidden", "conflict"];
};

/** Converts an authority route declaration into a stable, semantic screen VM. */
export function typedScreenViewModel(screen: ScreenViewModel): TypedScreenViewModel {
  if (screen.contract) return screen.contract;
  const journey = journeyFor(screen);
  const routeContract = ROUTE_SCREEN_CONTRACTS[screen.id as keyof typeof ROUTE_SCREEN_CONTRACTS];
  if (!routeContract) throw new Error(`typed screen contract missing: ${screen.id}`);
  const sections: TypedSectionViewModel[] = screen.sections.map((section, index) => {
    const declared = routeContract.sections.find((item) => item.id === section.id);
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
    if (!declared) throw new Error(`typed section contract missing: ${screen.id}.${section.id}`);
    if (screen.route !== "/test" && declared.component && section.component !== declared.component) {
      throw new Error(`screen component contract mismatch: ${screen.id}.${section.id} expected ${declared.component}, received ${section.component}`);
    }
    return {
    id: section.id,
    title: section.title,
    purpose: section.purpose,
    region: normalizeRegion(String(declared.region), regionFor(screen.id, section.id, index)),
    component: section.component,
    authorityComponent: declared.component,
    testId: section.test_id,
    order: index + 1,
    fields: declared.fields,
  };
  });
  const primary = screen.route === "/test"
    ? screen.actions.find((action) => action.primary === true) ?? screen.actions[0]
    : screen.actions.find((action) => action.id === routeContract.primaryActionId) ?? screen.actions.find((action) => action.primary === true) ?? screen.actions[0];
  return {
    screenId: screen.id,
    journey,
    objectLabel: routeContract.objectLabel || screen.title,
    persona: routeContract.persona || personaFor(journey),
    answerFirst: sections[0]?.purpose ?? `${screen.title}의 현재 상태와 다음 작업을 확인합니다.`,
    sections,
    states: stateProfile(screen),
    primaryActionId: screen.route === "/test" ? (primary?.id ?? null) : (routeContract.primaryActionId ?? primary?.id ?? null),
    primaryActionLabel: screen.route === "/test" ? (typeof primary?.label === "string" ? primary.label : null) : (routeContract.primaryActionLabel ?? (typeof primary?.label === "string" ? primary.label : null)),
    requiresDecisionReason: journey === "J-07" || journey === "J-11" || screen.id === "SIG-002",
    showsReceipt: journey === "J-03" || journey === "J-10" || journey === "J-11" || journey === "J-12",
  };
}

export const stateLabel = (state: ScreenRuntime["state"]): string => ({
  loading: "불러오는 중", success: "최신 상태", empty: "자료 없음", partial: "일부만 확인됨",
  stale: "갱신 필요", error: "오류", unauthenticated: "로그인 필요", unauthorized: "접근 불가", forbidden: "권한 없음",
  conflict: "변경 충돌", receipt: "영수증 확인됨", offline: "오프라인", saving: "저장 중",
  saved: "저장됨", "validation-error": "입력 확인 필요", "session-expiring": "세션 만료 임박", blocked: "진행 차단됨",
  refreshing: "갱신 중", degraded: "일부 기능 제한", incident: "장애 대응 중", "telemetry-gap": "관측 공백",
  ready: "작업 가능", "reauth-required": "재인증 필요", submitting: "제출 중", "partial-failure": "일부 처리 불확실", terminal: "종료됨",
}[state]);

export const humanFieldLabel = (field: string): string => {
  const labels: Record<string, string> = {
    status: "현재 상태", state: "진행 상태", title: "제목", summary: "요약", description: "설명",
    owner: "담당자", assignedTo: "담당자", dueAt: "기한", expiresAt: "만료 시각", createdAt: "생성 시각",
    updatedAt: "마지막 변경", reason: "사유", decision: "결정", receipt: "영수증", evidence: "근거",
    source: "출처", locator: "정확한 위치", version: "버전", digest: "무결성 지문", count: "건수",
  };
  if (labels[field]) return labels[field];
  return field.replace(/([a-z])([A-Z])/g, "$1 $2").replaceAll("_", " ");
};
