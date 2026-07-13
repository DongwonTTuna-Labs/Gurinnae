<script lang="ts">
import type { ScreenRuntime, ScreenViewModel } from "../index";
import InternalSidebar from "./InternalSidebar.svelte";
import PublicHeader from "./PublicHeader.svelte";
import ResponseHeader from "./ResponseHeader.svelte";
import ScreenActions from "./ScreenActions.svelte";
import ScreenSection from "./ScreenSection.svelte";

let { screen, runtime }: { screen: ScreenViewModel; runtime: ScreenRuntime } =
  $props();
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
    (runtime.pathname ?? "").startsWith("/internal/cases/"),
);
const responseStep = $derived(
  Math.min(4, Math.max(1, Number(screen.id.slice(-3)) || 1)),
);
const recordCount = $derived(
  Object.values(runtime.data).reduce<number>(
    (sum, value) =>
      sum +
      (isRecord(value) && Array.isArray(value.items) ? value.items.length : 0),
    0,
  ),
);
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
</script>

<svelte:head><title>{screen.title} · 구린네</title><meta name="description" content={`${screen.title} — 근거와 한계를 함께 확인합니다.`} /></svelte:head>

{#snippet stateSummary()}
  {#if runtime.notice}<p class="notice" role="status">{runtime.notice}</p>{/if}
  {#if runtime.errors.length > 0}
    <div class="error-summary" role="alert" tabindex="-1"><h2>요청을 완료하지 못했습니다</h2><ul>{#each runtime.errors as error}<li>{error}</li>{/each}</ul></div>
  {/if}
{/snippet}

{#snippet sections()}
  {#each screen.sections as section, index (section.id)}
    <section id={section.id} data-testid={section.test_id} data-component={section.component} class="section" class:primary={index === 0}>
      <div class="section-content"><ScreenSection {section} {screen} {runtime} {index} /></div>
    </section>
  {/each}
  <ScreenActions {screen} {runtime} />
{/snippet}

{#if surface === "public"}
  <div class="shell public-shell">
    <PublicHeader {runtime} />
    <main id="main-content" class="main public-main" data-screen-id={screen.id} data-archetype={screen.archetype}>
      {#if home}
        <header class="hero">
          <div class="hero-copy">
            <p class="eyebrow">공개자료를 근거로, 설명이 필요한 차이를 찾습니다</p>
            <h1>공공의 돈을<br />근거로 읽는 법</h1>
            <p class="lead">구린네는 계약·예산 공개자료에서 조사할 가치가 있는 이상 징후를 찾고, 확인된 사실과 중요한 미확인, 당사자 소명, 원본 근거를 함께 보여줍니다.</p>
            <p class="hero-note">자동 부패 판정기가 아닙니다. 가격 차이나 반복 계약은 조사 신호일 뿐이며 위법·비리를 의미하지 않습니다.</p>
          </div>
          <aside class="hero-board" aria-label="현재 공개 데이터 상태">
            <p class="board-label">현재 화면의 공개 계약</p>
            {#each screen.dataOperations.slice(0, 4) as operation}
              <div class="board-record"><strong>{operation.operation_id}</strong><span class="board-meta"><span>{operation.method}</span><span class="board-state">{runtime.state}</span></span></div>
            {/each}
          </aside>
        </header>
      {:else}
        <header class="page-heading"><nav class="breadcrumb" aria-label="현재 위치"><a href="/">홈</a><span aria-hidden="true">/</span><span>{screen.title}</span></nav><p class="eyebrow">{screen.id} · {screen.archetype}</p><h1>{screen.title}</h1><p class="lead">{screen.sections[0]?.purpose ?? "근거와 현재 상태를 함께 확인합니다."}</p></header>
      {/if}
      <p class="state badge neutral" data-state={runtime.state} aria-live="polite">현재 상태: {runtime.state}</p>
      {@render stateSummary()}{@render sections()}
    </main>
    <footer class="footer"><div class="footer-inner"><p>구린네는 자동 분석 결과를 범죄 또는 비리의 확정 판단으로 표현하지 않습니다.</p><p><a href="/editorial-policy">편집 정책</a> · <a href="/corrections">정정</a></p></div></footer>
  </div>
{:else if surface === "response"}
  <div class="form-shell">
    <ResponseHeader requestLabel={screen.id} />
    <main id="main-content" class="form-main" data-screen-id={screen.id} data-archetype={screen.archetype}>
      <div class="progress" aria-label={`4단계 중 ${responseStep}단계`}>{#each [1, 2, 3, 4] as step}<span class:active={step <= responseStep}></span>{/each}</div>
      <header class="page-heading"><p class="eyebrow">{responseStep} / 4 · 보호된 소명 절차</p><h1>{screen.title}</h1><p class="lead">{screen.sections[0]?.purpose ?? "요청 범위와 제출 내용을 확인합니다."}</p></header>
      <div class="request-summary"><strong>요청 식별자 {screen.id}</strong><span>세션·권한·기한은 제출 단계마다 서버가 다시 확인합니다.</span></div>
      <p class="state badge neutral" data-state={runtime.state} aria-live="polite">현재 상태: {runtime.state}</p>{@render stateSummary()}
      <div class="form-card">{@render sections()}</div>
    </main>
  </div>
{:else if surface === "auth"}
  <div class="form-shell auth-shell">
    <ResponseHeader requestLabel="내부 인증" />
    <main id="main-content" class="form-main auth-main" data-screen-id={screen.id} data-archetype={screen.archetype}>
      <header class="page-heading"><p class="eyebrow">보호된 내부 접근</p><h1>{screen.title}</h1><p class="lead">{screen.sections[0]?.purpose ?? "조직 계정과 현재 보안 상태를 확인합니다."}</p></header>
      <p class="state badge neutral" data-state={runtime.state} aria-live="polite">현재 상태: {runtime.state}</p>{@render stateSummary()}<div class="form-card">{@render sections()}</div>
    </main>
  </div>
{:else}
  <div class="internal-shell">
    <InternalSidebar pathname={runtime.pathname ?? ""} actorLabel={runtime.actorDisplayName ?? "로그인 필요"} />
    <div class="internal-content">
      <header class="internal-topbar"><div><span>내부 작업</span> <strong>{screen.title}</strong></div><span class="badge caution">{runtime.state}</span></header>
      <main id="main-content" class="internal-main" data-screen-id={screen.id} data-archetype={screen.archetype}>
        <header class="workspace-head"><div class="workspace-head-row"><div><div class="badges"><span class="badge info">{screen.id}</span><span class="badge neutral">{screen.archetype}</span></div><h1>{screen.title}</h1><div class="workspace-meta"><span>서버 권위 상태 {runtime.state}</span><span>응답 record {recordCount}건</span><span>operation {screen.dataOperations.length}개</span></div></div><a class="primary-button" href="#page-actions">다음 필수 작업</a></div></header>
        {@render stateSummary()}
        {#if workspace}
          <div class="workspace-grid">
            <nav class="task-rail" aria-label="현재 화면 영역">{#each screen.sections as section, index}<a class:active={index === 0} href={`#${section.id}`}><span>{section.title}</span><span class="task-count">{index + 1}</span></a>{/each}</nav>
            <div class="workspace-panel">{@render sections()}</div>
            <aside class="context-rail" aria-label="작업 맥락"><div class="context-section"><h2>결정 전 확인</h2><div class="blocker">현재 권한·freshness·expected version을 서버에서 재검증합니다.</div></div><div class="context-section"><h2>현재 상태</h2><p>{runtime.state}</p><p>오류 {runtime.errors.length}건</p></div><div class="context-section"><h2>연결 계약</h2><p>{screen.dataOperations.length}개 operation</p></div></aside>
          </div>
        {:else}<div class="workspace-panel operation-panel">{@render sections()}</div>{/if}
      </main>
    </div>
  </div>
{/if}
