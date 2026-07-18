<script lang="ts">
import { display, semanticRecords, visibleEntries } from "../data";
import type { ScreenRuntime } from "../index";
import { humanFieldLabel } from "../screen-contract";

let {
  runtime,
  mode = "cards",
  emptyLabel = "표시할 데이터가 없습니다.",
}: {
  runtime: ScreenRuntime;
  mode?: "cards" | "table" | "timeline" | "metrics";
  emptyLabel?: string;
} = $props();

const records = $derived(semanticRecords(runtime));
const keys = $derived(
  [
    ...new Set(
      records.flatMap(({ record }) =>
        visibleEntries(record).map(([key]) => key),
      ),
    ),
  ].slice(0, 8),
);
let scrollArea = $state<HTMLDivElement>();
</script>

{#if records.length === 0}
  <p class="empty-message" data-testid="empty-state">{emptyLabel}</p>
{:else if mode === "table"}
  <div class="table-scroll-controls" aria-label="표 이동 제어">
    <button type="button" aria-label="표를 왼쪽으로 이동" onclick={() => scrollArea?.scrollBy({ left: -240, behavior: "smooth" })}>←</button>
    <button type="button" aria-label="표를 오른쪽으로 이동" onclick={() => scrollArea?.scrollBy({ left: 240, behavior: "smooth" })}>→</button>
  </div>
  <div bind:this={scrollArea} class="table-scroll" role="region" aria-label="데이터 표 가로 스크롤 영역">
    <table>
      <caption class="sr-only">현재 화면에서 확인 가능한 기록</caption>
      <thead><tr><th scope="col">항목</th>{#each keys as key}<th scope="col">{humanFieldLabel(key)}</th>{/each}</tr></thead>
      <tbody>
        {#each records as item, rowIndex}
          <tr data-record-index={rowIndex}>
            <th scope="row">기록 {rowIndex + 1}</th>
            {#each keys as key}<td data-label={humanFieldLabel(key)}>{display(visibleEntries(item.record).find(([name]) => name === key)?.[1])}</td>{/each}
          </tr>
        {/each}
      </tbody>
    </table>
  </div>
{:else if mode === "timeline"}
  <ol class="timeline">
    {#each records as item, index}
      <li data-record-index={index}>
        <span class="timeline-marker" aria-hidden="true">{index + 1}</span>
        <div><strong>변경 기록 {index + 1}</strong><dl>{#each visibleEntries(item.record).slice(0, 6) as [key, value]}<div><dt>{humanFieldLabel(key)}</dt><dd>{display(value)}</dd></div>{/each}</dl></div>
      </li>
    {/each}
  </ol>
{:else}
  <div class:metric-grid={mode === "metrics"} class:record-grid={mode !== "metrics"}>
    {#each records as item, index}
      <article class="data-card" data-record-index={index}>
        <h3>기록 {index + 1}</h3>
        <dl>{#each visibleEntries(item.record).slice(0, mode === "metrics" ? 4 : 10) as [key, value]}<div><dt>{humanFieldLabel(key)}</dt><dd class:structured={typeof value === "object"}>{display(value)}</dd></div>{/each}</dl>
      </article>
    {/each}
  </div>
{/if}
