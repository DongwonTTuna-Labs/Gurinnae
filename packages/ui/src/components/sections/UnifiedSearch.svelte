<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import SectionHeading from "./SectionHeading.svelte";

let { section, screen, runtime, projection }: ScreenSectionProps = $props();
let query = $state("");
let role = $state("");
let type = $state("");
let filterState = $state("");
let initialized = $state(false);
const agentRunScreen = $derived(
  screen.id === "CAS-010" || screen.id === "CAS-011",
);
const showStateMessage = $derived(
  screen.sections.find((candidate) => candidate.component === "UnifiedSearch")
    ?.id === section.id,
);
$effect(() => {
  if (initialized) return;
  const searchParams = new URLSearchParams(
    (runtime.search ?? "").replace(/^\?/, ""),
  );
  query = searchParams.get(agentRunScreen ? "caseId" : "q") ?? "";
  role = searchParams.get("role") ?? "";
  type = searchParams.get(agentRunScreen ? "agentType" : "type") ?? "";
  filterState = searchParams.get(agentRunScreen ? "status" : "state") ?? "";
  initialized = true;
});
const stateMessage = $derived(
  runtime.state === "loading" || runtime.state === "initial-loading"
    ? "검색 결과를 불러오는 중입니다."
    : runtime.state === "error" || runtime.state === "server-error"
      ? "검색 결과를 불러오지 못했습니다. 잠시 후 다시 시도해 주세요."
      : runtime.state === "filtered-empty" || runtime.state === "empty"
        ? "조건에 맞는 결과가 없습니다. 필터를 줄여 다시 검색해 보세요."
        : projection?.fields.some((field) => field.known)
          ? "서버 권위 검색 결과를 확인했습니다."
          : "검색 결과가 아직 확인되지 않았습니다.",
);
</script>
<SectionHeading {section} kicker="검색" />
<form class="unified-search" method="GET" action={runtime.pathname ?? (screen.route === "/" ? "/search" : screen.route)} role="search">
  <label for={`${section.test_id}-query`}>{agentRunScreen ? "케이스 ID로 실행 기록 찾기" : "기관·업체·계약·사건 검색"}</label>
  <div class="unified-search__query">
    <input bind:value={query} id={`${section.test_id}-query`} name={agentRunScreen ? "caseId" : "q"} type="search" autocomplete="off" placeholder={agentRunScreen ? "UUID를 입력하세요" : "찾을 내용을 입력하세요"} />
    <button type="submit">검색</button>
  </div>
  <details class="unified-search__filters">
    <summary>역할·유형·상태 필터</summary>
    <div class="unified-search__filter-grid">
      {#if agentRunScreen}
        <label for={`${section.test_id}-type`}>에이전트 유형<select bind:value={type} id={`${section.test_id}-type`} name="agentType"><option value="">전체 유형</option><option value="ANALYST">분석</option><option value="SKEPTIC">반증 검토</option></select></label>
        <label for={`${section.test_id}-state`}>실행 상태<select bind:value={filterState} id={`${section.test_id}-state`} name="status"><option value="">전체 상태</option><option value="QUEUED">대기</option><option value="RUNNING">실행 중</option><option value="SUCCEEDED">성공</option><option value="FAILED">실패</option><option value="CANCELLED">취소</option><option value="BUDGET_BLOCKED">예산 차단</option><option value="POLICY_BLOCKED">정책 차단</option></select></label>
      {:else}
        <label for={`${section.test_id}-role`}>역할<select bind:value={role} id={`${section.test_id}-role`} name="role"><option value="">전체 역할</option><option value="agency">기관</option><option value="supplier">업체</option></select></label>
        <label for={`${section.test_id}-type`}>유형<select bind:value={type} id={`${section.test_id}-type`} name="type"><option value="">전체 유형</option><option value="contract">계약</option><option value="case">사건</option></select></label>
        <label for={`${section.test_id}-state`}>상태<select bind:value={filterState} id={`${section.test_id}-state`} name="state"><option value="">전체 상태</option><option value="active">진행 중</option><option value="closed">종료</option><option value="review">검토 필요</option></select></label>
      {/if}
    </div>
  </details>
  {#if showStateMessage}<p class="unified-search__status" aria-live="polite" role="status">{stateMessage}</p>{/if}
</form>

<style>
  .unified-search {
    display: grid;
    width: 100%;
    gap: 0.5rem;
    padding-block: 0.625rem;
    border-block: 1px solid var(--paper-200);
  }

  .unified-search > label {
    color: var(--ink-700);
    font-size: 0.8125rem;
    font-weight: 650;
  }

  .unified-search__query {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    gap: 0.5rem;
    align-items: stretch;
  }

  .unified-search__query input,
  .unified-search__filter-grid select {
    width: 100%;
    min-width: 0;
    min-height: var(--target-min);
    padding: 0.45rem 0.625rem;
    border: 1px solid var(--paper-200);
    border-radius: 4px;
    background: var(--paper-0);
    color: var(--ink-950);
    font-size: 0.875rem;
  }

  .unified-search__query button {
    min-height: var(--target-min);
    padding-inline: 0.875rem;
    border: 1px solid var(--blue-700);
    border-radius: 4px;
    background: var(--blue-700);
    color: var(--paper-0);
    cursor: pointer;
    font-size: 0.875rem;
    font-weight: 650;
  }

  .unified-search__filters {
    padding-top: 0.375rem;
    border-top: 1px solid var(--paper-200);
  }

  .unified-search__filters summary {
    min-height: var(--target-min);
    padding-block: 0.375rem;
    color: var(--ink-700);
    cursor: pointer;
    font-size: 0.8125rem;
    font-weight: 650;
  }

  .unified-search__filter-grid {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 0.5rem;
    margin-top: 0.375rem;
  }

  .unified-search__filter-grid label {
    display: grid;
    gap: 0.25rem;
    color: var(--ink-700);
    font-size: 0.75rem;
    font-weight: 650;
  }

  .unified-search__status {
    display: flex;
    gap: 0.5rem;
    align-items: flex-start;
    min-block-size: 1.5rem;
    margin: 0;
    color: var(--ink-700);
    font-size: 0.75rem;
    line-height: 1.4;
  }

  .unified-search__status::before {
    width: 0.45rem;
    height: 0.45rem;
    flex: 0 0 auto;
    margin-top: 0.4em;
    border-radius: 50%;
    background: var(--blue-500);
    content: "";
  }

  @media (max-width: 640px) {
    .unified-search__query,
    .unified-search__filter-grid {
      grid-template-columns: 1fr;
    }

    .unified-search__query button {
      width: 100%;
    }
  }

  @media (forced-colors: active) {
    .unified-search,
    .unified-search__filters,
    .unified-search__query input,
    .unified-search__filter-grid select,
    .unified-search__query button {
      border-color: CanvasText;
      background: Canvas;
      color: CanvasText;
    }
  }
</style>
