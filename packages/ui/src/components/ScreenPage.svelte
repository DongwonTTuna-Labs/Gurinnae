<script lang="ts">
import { onMount } from "svelte";
import type { ScreenRuntime, ScreenViewModel } from "../index";
import {
  formFieldId,
  stateLabel,
  typedScreenViewModel,
} from "../screen-contract";
import { projectScreen } from "../screen-projection";
import InternalSidebar from "./InternalSidebar.svelte";
import PublicHeader from "./PublicHeader.svelte";
import ResponseHeader from "./ResponseHeader.svelte";
import ScreenActions from "./ScreenActions.svelte";
import ScreenSection from "./ScreenSection.svelte";

let { screen, runtime }: { screen: ScreenViewModel; runtime: ScreenRuntime } =
  $props();
const contract = $derived(typedScreenViewModel(screen));
const projection = $derived(projectScreen(screen, runtime));
const surface = $derived(
  screen.id.startsWith("PUB-")
    ? "public"
    : screen.id.startsWith("RSP-")
      ? "response"
      : screen.id.startsWith("AUTH-")
        ? "auth"
        : "internal",
);
const home = $derived(screen.id === "PUB-001");
const workspace = $derived(
  screen.archetype === "WORKSPACE" ||
    screen.id === "INT-002" ||
    (runtime.pathname ?? "").startsWith("/internal/cases/"),
);
const responseStep = $derived(responseStepForScreen(screen.id));
const primaryActionAllowed = $derived(
  contract.primaryActionId !== null &&
    (!runtime.allowedActionIds ||
      runtime.allowedActionIds.includes(contract.primaryActionId)),
);
const busy = $derived(
  ["loading", "initial-loading", "refreshing", "saving", "submitting"].includes(
    runtime.state,
  ),
);
const evidenceLanding = $derived(screen.archetype === "EVIDENCE_LANDING");
const statusSectionId = $derived(
  screen.sections.some((section) => section.id === "status") ? "status" : null,
);
const caseTaskLinks = $derived.by(() => {
  const match = (runtime.pathname ?? "").match(/^\/internal\/cases\/([^/]+)/);
  if (!match?.[1]) return [] as const;
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
    { label: "Agent 실행", href: `${prefix}/agent-runs` },
    { label: "응답", href: `${prefix}/responses` },
    { label: "타임라인", href: `${prefix}/timeline` },
  ];
});
let activeSection = $state("");
$effect(() => {
  const firstSection = screen.sections[0]?.id ?? "";
  if (
    !activeSection ||
    !screen.sections.some((section) => section.id === activeSection)
  ) {
    activeSection = firstSection;
  }
});
onMount(() => {
  const reconcileHash = () => {
    const hash = window.location.hash.replace(/^#/, "");
    if (hash && screen.sections.some((section) => section.id === hash)) {
      activeSection = hash;
    }
  };
  reconcileHash();
  window.addEventListener("hashchange", reconcileHash);
  return () => window.removeEventListener("hashchange", reconcileHash);
});
const headingTestId = $derived(`${screen.id.toLowerCase()}__heading`);
const errorTestId = $derived(`${screen.id.toLowerCase()}__error_summary`);
const stateTestId = $derived(`${screen.id.toLowerCase()}__state_live`);
const primaryTarget = $derived(
  contract.primaryActionId
    ? `#action-${contract.primaryActionId}`
    : `#page-actions`,
);
const breadcrumbItems = $derived.by(() => {
  const path = runtime.pathname ?? screen.route;
  if (path === "/" || screen.id === "PUB-001") return [] as const;
  const segments = path.split("/").filter(Boolean);
  const labels: Record<string, string> = {
    cases: "사례",
    revisions: "개정판",
    evidence: "근거",
    claims: "주장",
    hypotheses: "가설",
    responses: "응답",
    review: "검토",
    preview: "미리보기",
    corrections: "정정",
    audit: "감사",
    sources: "출처",
    rules: "규칙",
    operations: "운영",
  };
  const items: { label: string; href: string }[] = [{ label: "홈", href: "/" }];
  let href = "";
  for (const segment of segments.slice(0, -1)) {
    href += `/${segment}`;
    items.push({ label: labels[segment] ?? segment, href });
  }
  items.push({ label: screen.title, href: path });
  return items;
});
function responseStepForScreen(screenId: string): number {
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

const responseStepLabels = [
  "요청 확인",
  "답변 작성",
  "첨부 검토",
  "제출 검토",
  "제출 완료",
];
const responseProgressState = (
  step: number,
): "not-started" | "in-progress" | "complete" | "error" =>
  runtime.errors.length > 0
    ? "error"
    : step < responseStep
      ? "complete"
      : step === responseStep
        ? "in-progress"
        : "not-started";

function sourceSection(sectionId: string): ScreenViewModel["sections"][number] {
  const source = screen.sections.find((section) => section.id === sectionId);
  if (!source)
    throw new Error(
      `screen section contract missing: ${screen.id}.${sectionId}`,
    );
  return source;
}

function errorTarget(message: string): string | null {
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

function stateTone(
  state: ScreenRuntime["state"],
): "neutral" | "info" | "status" | "caution" | "status-alert" {
  if (
    [
      "error",
      "server-error",
      "forbidden",
      "unauthorized",
      "conflict",
      "partial-failure",
      "incident",
      "unauthenticated",
    ].includes(state)
  )
    return "status-alert";
  if (
    [
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
    ].includes(state)
  )
    return "caution";
  if (
    [
      "success",
      "saved",
      "current",
      "healthy",
      "ready",
      "receipt",
      "terminal",
    ].includes(state)
  )
    return "status";
  return "neutral";
}
</script>

<svelte:head><title>{screen.title} · 구린네</title><meta name="description" content={`${screen.title} — 근거와 한계를 함께 확인합니다.`} /></svelte:head>

{#snippet stateSummary()}
  {#if runtime.notice}<p class="notice" role="status">{runtime.notice}</p>{/if}
  {#if runtime.errors.length > 0}
    <div id={projection.focus.errorSummary} class="error-summary" role="alert" tabindex="-1" data-testid={errorTestId} data-focus-target={projection.focus.errorSummary}><h2>요청을 완료하지 못했습니다</h2><ul>{#each runtime.errors as error, index}<li>{#if errorTarget(error)}<a href={`#${errorTarget(error)}`}>오류 {index + 1}: {error}</a>{:else}{error}{/if}</li>{/each}</ul></div>
  {/if}
{/snippet}

{#snippet sections(skipStatus = false)}
  {#each contract.sections as typedSection, index (typedSection.id)}
    {@const section = sourceSection(typedSection.id)}
    {#if !(skipStatus && typedSection.id === statusSectionId)}
      <section id={typedSection.id} tabindex="-1" aria-labelledby={`section-${typedSection.id}-heading`} data-testid={typedSection.testId} data-focus-target={projection.sections[typedSection.id]?.focusTarget} data-component={typedSection.component} data-projection-state={projection.sections[typedSection.id]?.state} class="section" class:primary={typedSection.region === "priority"}>
        <div class="section-content"><ScreenSection {section} {screen} {runtime} {index} projection={projection.sections[typedSection.id]} /></div>
      </section>
    {/if}
  {/each}
  <ScreenActions {screen} {runtime} />
{/snippet}

{#if surface === "public"}
  <div class="shell public-shell">
    <PublicHeader {runtime} />
            <main id="main-content" data-testid={projection.focus.main} data-focus-target={projection.focus.main} class="main public-main" data-screen-id={screen.id} data-archetype={screen.archetype} aria-busy={busy}>
      {#if evidenceLanding && statusSectionId}
        {@const statusSection = sourceSection(statusSectionId)}
        <section id={statusSection.id} tabindex="-1" aria-labelledby={`section-${statusSection.id}-heading`} data-testid={statusSection.test_id} data-focus-target={projection.sections[statusSection.id]?.focusTarget} data-component={statusSection.component} data-projection-state={projection.sections[statusSection.id]?.state} class="section pre-title-status">
          <div class="section-content"><ScreenSection section={statusSection} {screen} {runtime} index={0} projection={projection.sections[statusSection.id]} /></div>
        </section>
      {/if}
      {#if evidenceLanding}<p id={projection.focus.stateLive} class={`state badge ${stateTone(runtime.state)}`} data-state={runtime.state} data-testid={stateTestId} data-focus-target={projection.focus.stateLive} aria-live="polite">현재 상태: {stateLabel(runtime.state)}</p>{@render stateSummary()}{/if}
      {#if home}
        <header class="hero">
          <div class="hero-copy">
            <p class="eyebrow">공개자료를 근거로, 설명이 필요한 차이를 찾습니다</p>
            <h1 id={headingTestId} data-testid={projection.focus.heading} data-focus-target={projection.focus.heading}>공공의 돈을<br />근거로 읽는 법</h1>
            <p class="lead">구린네는 계약·예산 공개자료에서 조사할 가치가 있는 이상 징후를 찾고, 확인된 사실과 중요한 미확인, 당사자 소명, 원본 근거를 함께 보여줍니다.</p>
            <p class="hero-note">자동 부패 판정기가 아닙니다. 가격 차이나 반복 계약은 조사 신호일 뿐이며 위법·비리를 의미하지 않습니다.</p>
          </div>
          <aside class="hero-board" aria-label="현재 공개자료 상태">
            <p class="board-label">현재 공개자료 상태</p>
            <div class="board-record"><strong>{stateLabel(runtime.state)}</strong><span class="board-meta"><span>다음</span><a class="board-state" href={contract.primaryActionId === "search" ? "/search" : primaryTarget}>{contract.primaryActionLabel ?? "자료 탐색"}</a></span></div>
          </aside>
        </header>
      {:else}
        <header class="page-heading">{#if breadcrumbItems.length > 0}<nav class="breadcrumb" aria-label="현재 위치">{#each breadcrumbItems as item, index}{#if index > 0}<span aria-hidden="true">/</span>{/if}{#if index < breadcrumbItems.length - 1}<a href={item.href}>{item.label}</a>{:else}<span aria-current="page">{item.label}</span>{/if}{/each}</nav>{/if}<p class="eyebrow">{contract.journey} · {contract.persona}</p><h1 id={headingTestId} data-testid={projection.focus.heading} data-focus-target={projection.focus.heading}>{screen.title}</h1><p class="lead">{contract.answerFirst}</p></header>
      {/if}
      {#if !evidenceLanding}<p id={projection.focus.stateLive} class={`state badge ${stateTone(runtime.state)}`} data-state={runtime.state} data-testid={stateTestId} data-focus-target={projection.focus.stateLive} aria-live="polite">현재 상태: {stateLabel(runtime.state)}</p>{@render stateSummary()}{/if}
      {@render sections(evidenceLanding)}
    </main>
    <footer class="footer"><div class="footer-inner"><p>구린네는 자동 분석 결과를 범죄 또는 비리의 확정 판단으로 표현하지 않습니다.</p><nav aria-label="푸터 탐색"><a href="/methodology">검증 방법</a><a href="/coverage">데이터 범위</a><a href="/sources">출처</a><a href="/data">데이터 정책</a><a href="/api">API</a><a href="/about">소개</a><a href="/about/funding">후원·재정</a><a href="/about/governance">거버넌스</a><a href="/editorial-policy">편집 정책</a><a href="/corrections">정정</a><a href="/correction-request">정정 요청</a><a href="/accessibility">접근성</a><a href="/contact">도움말·문의</a><a href="/privacy">개인정보</a><a href="/terms">이용약관</a></nav></div></footer>
  </div>
{:else if surface === "response"}
  <div class="form-shell">
    <ResponseHeader requestLabel={contract.objectLabel} />
    <main id="main-content" data-testid={projection.focus.main} data-focus-target={projection.focus.main} class="form-main" data-screen-id={screen.id} data-archetype={screen.archetype} aria-busy={busy}>
      {#if responseStep > 0}
        <ol class="progress" aria-label="보호된 소명 절차 진행률">
          {#each responseStepLabels as label, index}
            {@const step = index + 1}
            {@const stepState = responseProgressState(step)}
            <li class:active={step <= responseStep} data-step-state={stepState} aria-current={step === responseStep ? "step" : undefined}><span>{step}</span><span>{label}</span></li>
          {/each}
        </ol>
      {/if}
      <header class="page-heading"><p class="eyebrow">{responseStep > 0 ? `${responseStep} / 5 · ` : ""}보호된 소명 절차</p><h1 id={headingTestId} data-testid={projection.focus.heading} data-focus-target={projection.focus.heading}>{screen.title}</h1><p class="lead">{contract.answerFirst}</p></header>
      {#if screen.id !== "RSP-008"}<div class="request-summary"><strong>{contract.objectLabel}</strong><span>세션·권한·제출 기한은 제출 단계마다 서버가 다시 확인됩니다.</span></div>{/if}
      <p id={projection.focus.stateLive} class={`state badge ${stateTone(runtime.state)}`} data-state={runtime.state} data-testid={stateTestId} data-focus-target={projection.focus.stateLive} aria-live="polite">현재 상태: {stateLabel(runtime.state)}</p>{@render stateSummary()}
      <div class="form-card">{@render sections()}</div>
    </main>
  </div>
{:else if surface === "auth"}
  <div class="form-shell auth-shell">
    <ResponseHeader requestLabel="내부 인증" />
    <main id="main-content" data-testid={projection.focus.main} data-focus-target={projection.focus.main} class="form-main auth-main" data-screen-id={screen.id} data-archetype={screen.archetype} aria-busy={busy}>
      <header class="page-heading"><p class="eyebrow">보호된 내부 접근</p><h1 id={headingTestId} data-testid={projection.focus.heading} data-focus-target={projection.focus.heading}>{screen.title}</h1><p class="lead">{screen.sections[0]?.purpose ?? "조직 계정과 현재 보안 상태를 확인합니다."}</p></header>
      <p id={projection.focus.stateLive} class={`state badge ${stateTone(runtime.state)}`} data-state={runtime.state} data-testid={stateTestId} data-focus-target={projection.focus.stateLive} aria-live="polite">현재 상태: {stateLabel(runtime.state)}</p>{@render stateSummary()}<div class="form-card">{@render sections()}</div>
    </main>
  </div>
{:else}
  <div class="internal-shell">
    <InternalSidebar pathname={runtime.pathname ?? ""} actorLabel={runtime.actorDisplayName ?? "로그인 필요"} />
    <div class="internal-content">
      <header class="internal-topbar"><div><span>내부 작업</span> <strong>{screen.title}</strong></div><span class={`badge ${stateTone(runtime.state)}`}>{stateLabel(runtime.state)}</span></header>
      <main id="main-content" data-testid={projection.focus.main} data-focus-target={projection.focus.main} class="internal-main" data-screen-id={screen.id} data-archetype={screen.archetype} aria-busy={busy}>
        <header class="workspace-head"><div class="workspace-head-row"><div><div class="badges"><span class="badge info">{contract.journey}</span><span class="badge neutral">{contract.persona}</span></div><h1 id={headingTestId} data-testid={projection.focus.heading} data-focus-target={projection.focus.heading}>{screen.title}</h1><div class="workspace-meta"><span>대상 {contract.objectLabel}</span><span>현재 상태 {stateLabel(runtime.state)}</span><span>다음 행동 {contract.primaryActionLabel ?? "확인 필요"}</span></div></div>{#if primaryActionAllowed && contract.primaryActionId}<a class="primary-button" href={primaryTarget}>{contract.primaryActionLabel ?? "다음 단계 열기"}</a>{:else if contract.primaryActionId}<span class="primary-button disabled" aria-disabled="true">권한 또는 상태 확인 필요</span>{/if}</div></header>
        {@render stateSummary()}
        {#if workspace}
          <div class="workspace-grid">
            <nav class="task-rail" aria-label="현재 화면 영역">{#each screen.sections as section, index}<a class:active={activeSection === section.id} href={`#${section.id}`} onclick={() => activeSection = section.id}><span>{section.title}</span><span class="task-count">{index + 1}</span></a>{/each}{#if caseTaskLinks.length > 0}<div class="task-rail-siblings" aria-label="케이스 작업 이동"><span>케이스 작업</span>{#each caseTaskLinks as link}<a href={link.href} class:active={runtime.pathname === link.href}>{link.label}</a>{/each}</div>{/if}</nav>
            <label class="compact-task-selector" for={`compact-task-${screen.id.toLowerCase()}`}>화면 영역<select id={`compact-task-${screen.id.toLowerCase()}`} value={activeSection} onchange={(event) => { const value = (event.currentTarget as HTMLSelectElement).value; if (value) window.location.hash = value; }}>{#each screen.sections as section}<option value={section.id}>{section.title}</option>{/each}</select></label>
            <div class="workspace-panel">{@render sections()}</div>
            <aside class="context-rail" aria-label="작업 맥락"><div class="context-section"><h2>결정 전 확인</h2><div class="blocker">{runtime.state === "unauthenticated" || runtime.state === "unauthorized" || runtime.state === "forbidden" ? "접근 권한을 확인한 뒤 다음 행동을 진행하세요." : runtime.errors.length > 0 ? "오류 원인을 확인하고 다시 시도하세요." : ["stale", "partial", "offline", "degraded", "telemetry-gap", "maintenance"].includes(runtime.state) ? "자료가 최신이 아니거나 일부만 확인되었습니다. 결정 전에 기준 시각과 미확인 범위를 확인하세요." : "서버가 최신 상태·권한·버전을 확인했습니다."}</div></div><div class="context-section"><h2>현재 상태</h2><p>{stateLabel(runtime.state)}</p><p>오류 {runtime.errors.length}건</p><p>세션 {runtime.sessionExpiresAt ?? "확인 필요"}</p></div><div class="context-section"><h2>연결 자료</h2><p>{screen.dataOperations.length}개 자료</p><p>다음 행동: {contract.primaryActionLabel ?? "확인 필요"}</p></div></aside>
          </div>
        {:else}<div class="workspace-panel operation-panel">{@render sections()}</div>{/if}
      </main>
    </div>
  </div>
{/if}
