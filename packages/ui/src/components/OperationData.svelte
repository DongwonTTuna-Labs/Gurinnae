<script lang="ts">
import { display } from "../data";
import type { ScreenRuntime, ScreenSectionProjection } from "../index";

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
const unknownFields = $derived(
  projection.fields.filter((field) => !field.known),
);
const stateMessage = $derived(
  projection.state === "BLOCKED"
    ? (projection.errorMessage ?? "확인이 끝나지 않아 표시를 보류했습니다.")
    : projection.state === "UNKNOWN"
      ? "확인 가능한 typed projection이 없습니다."
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
  {#if stateMessage}<p class="inline-state" class:conflict={projection.state === "BLOCKED" || projection.state === "ERROR"} role={projection.state === "BLOCKED" || projection.state === "ERROR" ? "alert" : "status"}>{stateMessage}</p>{/if}
  {#if fields.length === 0}
    <p class="empty-message" data-testid="empty-state">{emptyLabel}</p>
  {:else if mode === "table"}
    <div class="table-scroll" role="region" aria-label="확인된 projection 표"><table><caption class="sr-only">서버 권위 projection</caption><thead><tr><th scope="col">항목</th><th scope="col">값</th></tr></thead><tbody>{#each fields as field}<tr><th scope="row">{field.label}</th><td data-label={field.label}>{#if destinationFor(field.name)}<a href={destinationFor(field.name) ?? undefined}>{display(field.value)}</a>{:else}{display(field.value)}{/if}</td></tr>{/each}</tbody></table></div>
  {:else if mode === "timeline"}
    <ol class="timeline">{#each fields as field, index}<li><span class="timeline-marker" aria-hidden="true">{index + 1}</span><span class="sr-only">기록 {index + 1}</span><div><strong>{field.label}</strong><p>{display(field.value)}</p></div></li>{/each}</ol>
  {:else}
    <div class:metric-grid={mode === "metrics"} class:record-grid={mode !== "metrics"}><article class="data-card"><h3>서버 권위 projection</h3><dl>{#each fields as field}<div><dt>{field.label}</dt><dd>{#if destinationFor(field.name)}<a href={destinationFor(field.name) ?? undefined}>{display(field.value)}</a>{:else}{display(field.value)}{/if}</dd></div>{/each}</dl></article></div>
  {/if}
  {#if unknownFields.length > 0}
    <section class="unknown-fields" aria-label="확인하지 못한 항목">
      <h3>아직 확인하지 못한 항목</h3>
      <ul>
        {#each unknownFields as field}
          <li><strong>{field.label}</strong><span>서버 권위 projection에 이 항목이 없어 확인이 필요합니다.</span></li>
        {/each}
      </ul>
    </section>
  {/if}
</div>
