<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, screen, runtime, projection }: ScreenSectionProps = $props();
const analysis = $derived(projection?.analysis);
const metrics = $derived(analysis?.visualizations ?? []);
const rows = $derived(analysis?.provenanceRows ?? []);
const showMetrics = $derived(
  (screen.id === "CAS-010" && section.id === "runs") ||
    (screen.id === "CAS-011" && section.id === "output"),
);
const showProvenance = $derived(
  screen.id === "CAS-011" && section.id === "inputs",
);
</script>

<SectionHeading {section} kicker="권위 분석 결과" />
<p class="analysis-projection-note">서버가 검증한 분석 모델만 표시합니다. 표와 근거 행은 키보드·스크린 리더로도 확인할 수 있습니다.</p>
{#if projection}
  <OperationData {runtime} {projection} mode="cards" emptyLabel="현재 계약에서 확인 가능한 분석 항목이 없습니다." />
{/if}

{#if showMetrics && metrics.length > 0}
  <section class="analysis-visualizations" aria-labelledby={`${section.id}-visualizations-heading`} data-testid={`${section.id}-visualizations`}>
    <h3 id={`${section.id}-visualizations-heading`}>시각화 대안</h3>
    {#each metrics as metric (metric.visualizationId)}
      <article class="analysis-visualization" data-visualization-id={metric.visualizationId}>
        <h4>{metric.title}</h4>
        <p class="analysis-narrative">{metric.narrativeAlternative}</p>
        <div class="table-scroll" role="region" aria-label={`${metric.title} 표 대안`}>
          <table data-testid={`${section.id}-${metric.visualizationId}-table`}>
            <caption>{metric.tableAlternative.caption}</caption>
            <thead><tr>{#each metric.tableAlternative.headers as header}<th scope="col">{header}</th>{/each}</tr></thead>
            <tbody>{#each metric.tableAlternative.rows as row}<tr>{#each row as cell, index}<td data-label={metric.tableAlternative.headers[index] ?? `값 ${index + 1}`}>{cell}</td>{/each}</tr>{/each}</tbody>
          </table>
        </div>
        <p class="projection-provenance">표 무결성 지문: <code>{metric.tableAlternative.dataSha256}</code></p>
      </article>
    {/each}
  </section>
{/if}

{#if showProvenance && rows.length > 0}
  <section class="analysis-provenance" aria-labelledby={`${section.id}-provenance-heading`} data-testid={`${section.id}-provenance`}>
    <h3 id={`${section.id}-provenance-heading`}>접근 가능한 provenance graph</h3>
    <div class="table-scroll" role="region" aria-label="근거 연결 표">
      <table data-testid={`${section.id}-provenance-table`}>
        <caption>실행에서 확인한 근거 연결</caption>
        <thead><tr><th scope="col">순서</th><th scope="col">출발</th><th scope="col">관계</th><th scope="col">도착</th><th scope="col">근거 지문</th></tr></thead>
        <tbody>
          {#each rows as row}
            <tr>
              <td data-label="순서">{row.ordinal + 1}</td>
              <td data-label="출발">{#if row.sourceHref?.startsWith("/")}<a href={row.sourceHref}>{row.fromLabel}</a>{:else}{row.fromLabel}{/if}</td>
              <td data-label="관계">{row.relationLabel}</td><td data-label="도착">{row.toLabel}</td><td data-label="근거 지문"><code>{row.factSha256}</code></td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  </section>
{/if}
