<script lang="ts">
import type { ScreenRuntime, ScreenSectionProjection } from "../index";
import ProjectionValue from "./ProjectionValue.svelte";

let {
  runtime,
  projection,
  mode = "cards",
  emptyLabel = "표시할 데이터가 없습니다.",
}: {
  runtime: ScreenRuntime;
  projection: ScreenSectionProjection;
  mode?: "cards" | "table" | "timeline" | "metrics";
  emptyLabel?: string;
} = $props();

const fields = $derived(
  projection.fields.filter((field) => field.known && field.value !== null),
);
const stateMessage = $derived(
  projection.state === "BLOCKED"
    ? (projection.errorMessage ?? "확인이 끝나지 않아 표시를 보류했습니다.")
    : projection.state === "UNKNOWN"
      ? "확인 가능한 자료가 없습니다."
      : projection.state === "LOADING"
        ? "자료를 불러오는 중입니다."
        : projection.state === "STALE"
          ? "자료가 갱신되지 않아 최신 여부를 확인해야 합니다."
          : projection.state === "ERROR"
            ? (projection.errorMessage ?? "자료를 불러오지 못했습니다.")
            : projection.state === "PARTIAL"
              ? "일부 자료만 확인되어 미확인 범위를 함께 표시합니다."
              : null,
);
const destinationFor = (name: string): string | null =>
  runtime.destinations?.[name] ??
  runtime.destinations?.[`${projection.sectionId}.${name}`] ??
  null;
</script>

<div class="projection-data" data-projection-state={projection.state} aria-busy={runtime.state === "loading"}>
  {#if stateMessage}<p class="inline-state" class:conflict={projection.state === "BLOCKED" || projection.state === "ERROR"} role={projection.state === "BLOCKED" || projection.state === "ERROR" ? "alert" : "status"}>{stateMessage}</p>
  {:else if fields.length === 0}
    <p class="empty-message" data-testid="empty-state">{emptyLabel}</p>
  {:else if mode === "table"}
    <div class="table-scroll" role="region" aria-label="확인된 자료 표"><table><caption class="sr-only">확인된 자료</caption><thead><tr><th scope="col">항목</th><th scope="col">값</th></tr></thead><tbody>{#each fields as field}<tr><th scope="row">{field.label}</th><td data-label={field.label}><ProjectionValue name={field.name} label={field.label} value={field.value} href={destinationFor(field.name)} /></td></tr>{/each}</tbody></table></div>
  {:else if mode === "timeline"}
    <ol class="timeline">{#each fields as field, index}<li><span class="timeline-marker" aria-hidden="true">{index + 1}</span><span class="sr-only">기록 {index + 1}</span><div><strong>{field.label}</strong><div class="timeline-value"><ProjectionValue name={field.name} label={field.label} value={field.value} /></div></div></li>{/each}</ol>
  {:else}
    <div class:metric-grid={mode === "metrics"} class:record-grid={mode !== "metrics"}><article class="data-card"><h3>확인된 자료</h3><dl>{#each fields as field}<div><dt>{field.label}</dt><dd><ProjectionValue name={field.name} label={field.label} value={field.value} href={destinationFor(field.name)} /></dd></div>{/each}</dl></article></div>
  {/if}
</div>

<style>
  .projection-data {
    display: grid;
    gap: 0.375rem;
    min-width: 0;
    font-size: 0.875rem;
    line-height: 1.4;
  }

  .inline-state,
  .empty-message {
    display: flex;
    gap: 0.5rem;
    align-items: flex-start;
    margin: 0;
    padding: 0.375rem 0.5rem;
    border-block: 1px solid var(--paper-200);
    background: var(--paper-50);
    color: var(--ink-700);
    font-size: 0.875rem;
  }

  .inline-state::before,
  .empty-message::before {
    width: 0.45rem;
    height: 0.45rem;
    flex: 0 0 auto;
    margin-top: 0.4em;
    border-radius: 50%;
    background: var(--blue-500);
    content: "";
  }

  .inline-state.conflict { border-color: var(--red-500); background: var(--red-50); color: var(--red-900); }
  .inline-state.conflict::before { background: var(--red-500); }

  [data-projection-state="STALE"] .inline-state,
  [data-projection-state="PARTIAL"] .inline-state { border-color: var(--amber-500); background: var(--amber-50); color: var(--amber-900); }

  [data-projection-state="STALE"] .inline-state::before,
  [data-projection-state="PARTIAL"] .inline-state::before { background: var(--amber-500); }
  .empty-message::before { background: var(--ink-300); }

  .table-scroll {
    max-width: 100%;
    overflow-x: auto;
    border-block: 1px solid var(--paper-200);
    background: var(--paper-0);
  }

  table {
    width: 100%;
    table-layout: fixed;
    border-collapse: collapse;
    text-align: left;
    font-size: 0.875rem;
  }

  th,
  td {
    min-width: 0;
    padding: 0.375rem 0.5rem;
    border-bottom: 1px solid var(--paper-200);
    line-height: 1.4;
    overflow-wrap: anywhere;
    vertical-align: top;
  }

  tr:last-child > :is(th, td) { border-bottom: 0; }

  thead th {
    border-bottom-color: var(--ink-700);
    color: var(--ink-500);
    font-size: 0.75rem;
    font-weight: 650;
  }

  th:first-child { width: 34%; }
  tbody th { color: var(--ink-700); font-weight: 650; }

  .timeline {
    display: grid;
    gap: 0;
    margin: 0;
    padding: 0;
    border-top: 1px solid var(--paper-200);
    list-style: none;
  }

  .timeline li {
    display: grid;
    grid-template-columns: 1.75rem minmax(0, 1fr);
    gap: 0.625rem;
    align-items: start;
    padding: 0.375rem 0.25rem;
    border-bottom: 1px solid var(--paper-200);
  }

  .timeline-marker {
    display: grid;
    width: 1.5rem;
    height: 1.5rem;
    place-items: center;
    border: 1px solid var(--blue-500);
    border-radius: 4px;
    color: var(--blue-700);
    font-size: 0.75rem;
    font-weight: 650;
  }

  .timeline li > div { min-width: 0; }
  .timeline strong { font-size: 0.875rem; font-weight: 650; }

  .timeline-value { margin-top: 0.125rem; color: var(--ink-700); font-size: 0.875rem; overflow-wrap: anywhere; }

  .record-grid { display: block; min-width: 0; }
  .metric-grid { display: grid; min-width: 0; }

  .data-card {
    min-width: 0;
    padding: 0;
    border: 0;
    border-radius: 0;
    background: transparent;
  }

  .data-card h3 {
    margin: 0;
    padding: 0.375rem 0.5rem;
    border-block: 1px solid var(--paper-200);
    color: var(--ink-500);
    font-size: 0.75rem;
    font-weight: 650;
  }

  .data-card dl {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 19rem), 1fr));
    margin: 0;
  }

  .data-card dl > div {
    display: grid;
    grid-template-columns: minmax(7rem, 34%) minmax(0, 1fr);
    gap: 0.5rem;
    min-width: 0;
    padding: 0.375rem 0.5rem;
    border-bottom: 1px solid var(--paper-200);
  }

  .data-card dt { color: var(--ink-500); font-size: 0.75rem; font-weight: 650; }
  .data-card dd { min-width: 0; margin: 0; font-size: 0.875rem; overflow-wrap: anywhere; }

  .metric-grid .data-card dl {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 19rem), 1fr));
  }

  .metric-grid .data-card dl > div { display: block; }
  @media (max-width: 620px) {
    th:first-child { width: 40%; }

    .data-card dl > div {
      grid-template-columns: 1fr;
      gap: 0.125rem;
    }
  }
</style>
