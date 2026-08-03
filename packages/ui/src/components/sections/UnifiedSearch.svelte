<script lang="ts">
import { presentEnumValue } from "../../enum-presentation";
import type { ScreenSectionProps } from "../../index";
import {
  isPublicLedgerFilterScreen,
  urlFilterArrayValues,
  urlFilterContractFor,
  urlFilterScalarValue,
} from "../../url-filter-contracts";
import PublicLedgerFilters from "./PublicLedgerFilters.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, screen, runtime, projection }: ScreenSectionProps = $props();
let query = $state("");
let role = $state("");
let type = $state("");
let filterState = $state("");
let urlFilters = $state({
  q: "",
  types: "",
  status: "",
  eventType: "",
  actorId: "",
  from: "",
  to: "",
  sort: "",
});
let initialized = $state(false);
const agentRunScreen = $derived(
  screen.id === "CAS-010" || screen.id === "CAS-011",
);
const urlFilterContract = $derived(urlFilterContractFor(screen.id));
const showStateMessage = $derived(
  screen.sections.find((candidate) => candidate.component === "UnifiedSearch")
    ?.id === section.id,
);
const ownsPrimaryUrlAction = $derived(
  urlFilterContract !== undefined && showStateMessage,
);
const formAction = $derived(
  runtime.pathname ?? (screen.route === "/" ? "/search" : screen.route),
);

function repeatedValue(searchParams: URLSearchParams, key: string): string {
  return searchParams.getAll(key).join(", ");
}

$effect(() => {
  if (initialized) return;
  const searchParams = new URLSearchParams(
    (runtime.search ?? "").replace(/^\?/, ""),
  );
  query = searchParams.get(agentRunScreen ? "caseId" : "q") ?? "";
  role = searchParams.get("role") ?? "";
  type = searchParams.get(agentRunScreen ? "agentType" : "type") ?? "";
  filterState = searchParams.get(agentRunScreen ? "status" : "state") ?? "";
  urlFilters = {
    q: searchParams.get("q") ?? "",
    types: repeatedValue(searchParams, "types"),
    status: repeatedValue(searchParams, "status"),
    eventType: repeatedValue(searchParams, "eventType"),
    actorId: searchParams.get("actorId") ?? "",
    from: searchParams.get("from") ?? "",
    to: searchParams.get("to") ?? "",
    sort: searchParams.get("sort") ?? "",
  };
  initialized = true;
});
const stateMessage = $derived(
  runtime.state === "awaiting-query"
    ? "검색어 입력 대기"
    : runtime.state === "loading" || runtime.state === "initial-loading"
      ? "검색 결과를 불러오는 중입니다."
      : runtime.state === "error" || runtime.state === "server-error"
        ? "검색 결과를 불러오지 못했습니다. 잠시 후 다시 시도해 주세요."
        : runtime.state === "filtered-empty" || runtime.state === "empty"
          ? "조건에 맞는 결과가 없습니다. 필터를 줄여 다시 검색해 보세요."
          : projection?.fields.some((field) => field.known)
            ? "검색 결과를 확인했습니다."
            : "검색 결과가 아직 확인되지 않았습니다.",
);
</script>
<SectionHeading {section} kicker="검색" />
{#if urlFilterContract && isPublicLedgerFilterScreen(screen.id)}
<PublicLedgerFilters
  screenId={screen.id}
  {section}
  {runtime}
  contract={urlFilterContract}
  {formAction}
  {showStateMessage}
  {stateMessage}
/>
{:else if urlFilterContract}
<form
  id={ownsPrimaryUrlAction ? `action-${urlFilterContract.actionId}` : undefined}
  class="unified-search"
  method="GET"
  action={formAction}
  role="search"
  data-action-id={ownsPrimaryUrlAction ? urlFilterContract.actionId : undefined}
>
  {#if screen.id === "INT-003"}
    <label for={`${section.test_id}-query`}>식별자·텍스트·위치 검색</label>
    <div class="unified-search__query">
      <input bind:value={urlFilters.q} id={`${section.test_id}-query`} data-query-key="q" type="search" autocomplete="off" placeholder="찾을 내용을 입력하세요" />
      <button type="submit">{urlFilterContract.actionLabel}</button>
    </div>
    <details class="unified-search__filters">
      <summary>객체 유형·상태·정렬</summary>
      <div class="unified-search__filter-grid">
        <label for={`${section.test_id}-types`}>객체 유형 (쉼표로 구분)<input bind:value={urlFilters.types} id={`${section.test_id}-types`} data-query-key="types" autocomplete="off" placeholder="사건, 신호, 근거, 실행" /></label>
        <label for={`${section.test_id}-status`}>상태 (쉼표로 구분)<input bind:value={urlFilters.status} id={`${section.test_id}-status`} data-query-key="status" autocomplete="off" /></label>
        <label for={`${section.test_id}-sort`}>정렬<select bind:value={urlFilters.sort} id={`${section.test_id}-sort`} data-query-key="sort"><option value="">기본 정렬</option><option value="relevance">관련도</option><option value="updated_desc">최근 갱신순</option><option value="title_asc">제목순</option></select></label>
      </div>
    </details>
  {:else}
    <label for={`${section.test_id}-event-type`}>이벤트 유형 (쉼표로 구분)</label>
    <div class="unified-search__query">
      <input bind:value={urlFilters.eventType} id={`${section.test_id}-event-type`} data-query-key="eventType" autocomplete="off" placeholder="개정본 공개, 사건 갱신" />
      <button type="submit">{urlFilterContract.actionLabel}</button>
    </div>
    <details class="unified-search__filters">
      <summary>행위자·기간·정렬</summary>
      <div class="unified-search__filter-grid">
        <label for={`${section.test_id}-actor-id`}>행위자 식별자<input bind:value={urlFilters.actorId} id={`${section.test_id}-actor-id`} data-query-key="actorId" autocomplete="off" /></label>
        <label for={`${section.test_id}-from`}>시작 시각<input bind:value={urlFilters.from} id={`${section.test_id}-from`} data-query-key="from" autocomplete="off" placeholder="예: 2026년 7월 27일 00:00 UTC" /></label>
        <label for={`${section.test_id}-to`}>종료 시각<input bind:value={urlFilters.to} id={`${section.test_id}-to`} data-query-key="to" autocomplete="off" placeholder="예: 2026년 7월 27일 23:59 UTC" /></label>
        <label for={`${section.test_id}-sort`}>정렬<select bind:value={urlFilters.sort} id={`${section.test_id}-sort`} data-query-key="sort"><option value="">기본 정렬</option><option value="occurred_desc">최신순</option><option value="occurred_asc">오래된순</option></select></label>
      </div>
    </details>
  {/if}
  {#if screen.id === "INT-003"}
    {#if urlFilterScalarValue(urlFilters.q)}<input type="hidden" name="q" value={urlFilterScalarValue(urlFilters.q)} />{/if}
    {#each urlFilterArrayValues(urlFilters.types) as value}<input type="hidden" name="types" {value} />{/each}
    {#each urlFilterArrayValues(urlFilters.status) as value}<input type="hidden" name="status" {value} />{/each}
    {#if urlFilterScalarValue(urlFilters.sort)}<input type="hidden" name="sort" value={urlFilterScalarValue(urlFilters.sort)} />{/if}
  {:else}
    {#each urlFilterArrayValues(urlFilters.eventType) as value}<input type="hidden" name="eventType" {value} />{/each}
    {#if urlFilterScalarValue(urlFilters.actorId)}<input type="hidden" name="actorId" value={urlFilterScalarValue(urlFilters.actorId)} />{/if}
    {#if urlFilterScalarValue(urlFilters.from)}<input type="hidden" name="from" value={urlFilterScalarValue(urlFilters.from)} />{/if}
    {#if urlFilterScalarValue(urlFilters.to)}<input type="hidden" name="to" value={urlFilterScalarValue(urlFilters.to)} />{/if}
    {#if urlFilterScalarValue(urlFilters.sort)}<input type="hidden" name="sort" value={urlFilterScalarValue(urlFilters.sort)} />{/if}
  {/if}
  {#if showStateMessage}
    <p class="unified-search__status" aria-live="polite" role="status">{stateMessage}</p>
  {/if}
</form>
{:else}
<form class="unified-search" method="GET" action={formAction} role="search">
  <label for={`${section.test_id}-query`}>{agentRunScreen ? "사건 식별자로 실행 기록 찾기" : "기관·업체·계약·사건 검색"}</label>
  <div class="unified-search__query">
    <input bind:value={query} id={`${section.test_id}-query`} name={agentRunScreen ? "caseId" : "q"} type="search" autocomplete="off" placeholder={agentRunScreen ? "식별자 입력" : "찾을 내용을 입력하세요"} />
    <button type="submit">검색</button>
  </div>
  <details class="unified-search__filters">
    <summary>역할·유형·상태 필터</summary>
    <div class="unified-search__filter-grid">
      {#if agentRunScreen}
        <label for={`${section.test_id}-type`}>에이전트 유형<select bind:value={type} id={`${section.test_id}-type`} name="agentType"><option value="">전체 유형</option><option value="ANALYST">{presentEnumValue("ANALYST")}</option><option value="SKEPTIC">{presentEnumValue("SKEPTIC")}</option></select></label>
        <label for={`${section.test_id}-state`}>실행 상태<select bind:value={filterState} id={`${section.test_id}-state`} name="status"><option value="">전체 상태</option><option value="QUEUED">{presentEnumValue("QUEUED")}</option><option value="RUNNING">{presentEnumValue("RUNNING")}</option><option value="SUCCEEDED">{presentEnumValue("SUCCEEDED")}</option><option value="FAILED">{presentEnumValue("FAILED")}</option><option value="CANCELLED">{presentEnumValue("CANCELLED")}</option><option value="BUDGET_BLOCKED">{presentEnumValue("BUDGET_BLOCKED")}</option><option value="POLICY_BLOCKED">{presentEnumValue("POLICY_BLOCKED")}</option></select></label>
      {:else}
        <label for={`${section.test_id}-role`}>역할<select bind:value={role} id={`${section.test_id}-role`} name="role"><option value="">전체 역할</option><option value="agency">기관</option><option value="supplier">업체</option></select></label>
        <label for={`${section.test_id}-type`}>유형<select bind:value={type} id={`${section.test_id}-type`} name="type"><option value="">전체 유형</option><option value="contract">계약</option><option value="case">사건</option></select></label>
        <label for={`${section.test_id}-state`}>상태<select bind:value={filterState} id={`${section.test_id}-state`} name="state"><option value="">전체 상태</option><option value="active">진행 중</option><option value="closed">종료</option><option value="review">검토 필요</option></select></label>
      {/if}
    </div>
  </details>
  {#if showStateMessage}<p class="unified-search__status" aria-live="polite" role="status">{stateMessage}</p>{/if}
</form>
{/if}

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
  .unified-search__filter-grid input,
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
    .unified-search__filter-grid input,
    .unified-search__filter-grid select,
    .unified-search__query button {
      border-color: CanvasText;
      background: Canvas;
      color: CanvasText;
    }
  }
</style>
