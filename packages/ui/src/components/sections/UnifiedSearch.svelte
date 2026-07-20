<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import SectionHeading from "./SectionHeading.svelte";

let { section, screen, runtime, projection }: ScreenSectionProps = $props();
let query = $state("");
let role = $state("");
let type = $state("");
let filterState = $state("");
const records = $derived.by(() => {
  return projection?.fields.filter((field) => field.known) ?? [];
});
const stateMessage = $derived(
  runtime.state === "loading" || runtime.state === "initial-loading"
    ? "검색 결과를 불러오는 중입니다."
    : runtime.state === "error" || runtime.state === "server-error"
      ? "검색 결과를 불러오지 못했습니다. 잠시 후 다시 시도해 주세요."
      : runtime.state === "filtered-empty" || runtime.state === "empty"
        ? "조건에 맞는 결과가 없습니다. 필터를 줄여 다시 검색해 보세요."
        : `${records.length}개 결과`,
);
</script>
<SectionHeading {section} kicker="검색" />
<form class="unified-search" method="GET" action={screen.route === "/" ? "/search" : screen.route} role="search">
  <label for={`${section.test_id}-query`}>기관·업체·계약·사건 검색</label>
  <div class="unified-search__query">
    <input bind:value={query} id={`${section.test_id}-query`} name="q" type="search" autocomplete="off" placeholder="찾을 내용을 입력하세요" />
    <button type="submit">검색</button>
  </div>
  <details class="unified-search__filters">
    <summary>역할·유형·상태 필터</summary>
    <div class="unified-search__filter-grid">
      <label for={`${section.test_id}-role`}>역할<select bind:value={role} id={`${section.test_id}-role`} name="role"><option value="">전체 역할</option><option value="agency">기관</option><option value="supplier">업체</option></select></label>
      <label for={`${section.test_id}-type`}>유형<select bind:value={type} id={`${section.test_id}-type`} name="type"><option value="">전체 유형</option><option value="contract">계약</option><option value="case">사건</option></select></label>
      <label for={`${section.test_id}-state`}>상태<select bind:value={filterState} id={`${section.test_id}-state`} name="state"><option value="">전체 상태</option><option value="active">진행 중</option><option value="closed">종료</option><option value="review">검토 필요</option></select></label>
    </div>
  </details>
  <p class="unified-search__status" aria-live="polite" role="status">{stateMessage}</p>
</form>

<style>
  .unified-search__query { display: flex; gap: var(--space-2); align-items: end; }
  .unified-search__query input { flex: 1; min-width: 0; }
  .unified-search__filters { margin-top: var(--space-3); }
  .unified-search__filter-grid { display: grid; gap: var(--space-3); grid-template-columns: repeat(3, minmax(0, 1fr)); margin-top: var(--space-3); }
  .unified-search__filter-grid label { display: grid; gap: var(--space-1); }
  .unified-search__status { min-block-size: 1.5rem; margin-block: var(--space-3) 0; }
  @media (max-width: 640px) {
    .unified-search__query { align-items: stretch; flex-direction: column; }
    .unified-search__filter-grid { grid-template-columns: 1fr; }
  }
</style>
