<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import type { ProjectionField } from "../../screen-projection";
import SectionHeading from "./SectionHeading.svelte";

let { section, screen, runtime, projection }: ScreenSectionProps = $props();
const facts = $derived(
  projection?.fields.filter(
    (field) =>
      field.known &&
      !field.name.startsWith("metric.") &&
      !field.name.startsWith("funnel."),
  ) ?? [],
);
const metrics = $derived(
  projection?.fields
    .filter((field) => field.name.startsWith("metric."))
    .reduce((groups, field) => {
      const metricId = field.name.split(".")[1] ?? "unknown";
      const current = groups.get(metricId) ?? [];
      current.push(field);
      groups.set(metricId, current);
      return groups;
    }, new Map<string, ProjectionField[]>()) ??
    new Map<string, ProjectionField[]>(),
);
const funnel = $derived(
  projection?.fields.filter((field) => field.name.startsWith("funnel.")) ?? [],
);
const stateMessage = $derived(
  projection?.state === "READY"
    ? "서버 확인 상업 지표 · 기준 시각·근거 지문"
    : (projection?.errorMessage ??
        "수익·비용·유지 지표는 누락 근거를 보완하기 전 확정할 수 없습니다."),
);
</script>

<SectionHeading {section} kicker="사업 상태" />
<div class="business-health" data-testid="business-health-vm" data-state={projection?.state ?? "UNKNOWN"}>
  <p class="business-health-lead">AI 제안이나 페이지 조회만으로 유료 가치를 확정하지 않습니다.</p>
  <p class:inline-state={projection?.state !== "READY"} class="inline-state" role={projection?.state === "ERROR" || projection?.state === "BLOCKED" ? "alert" : "status"}>{stateMessage}</p>
  {#if projection}
    <dl class="business-health-facts">
      {#each facts as field (field.name)}
        <div class="business-health-fact"><dt>{field.label}</dt><dd>{field.value ?? "확인되지 않음"}</dd></div>
      {/each}
    </dl>
    {#if funnel.length > 0}
      <section aria-labelledby="business-health-funnel-heading">
        <h3 id="business-health-funnel-heading">고객 여정 단계</h3>
        <ul class="business-health-funnel">
          {#each funnel as field (field.name)}<li><span>{field.label}</span><strong>{field.value ?? "확인되지 않음"}</strong></li>{/each}
        </ul>
      </section>
    {/if}
    {#if metrics.size > 0}
      <section aria-labelledby="business-health-metrics-heading">
        <h3 id="business-health-metrics-heading">지표별 근거</h3>
        {#each [...metrics.entries()] as [metricId, metricFields] (metricId)}
          <details class="business-health-metric" open>
            <summary>{metricId}</summary>
            <dl>{#each metricFields as field (field.name)}<div><dt>{field.label}</dt><dd>{field.value ?? "확인되지 않음"}</dd></div>{/each}</dl>
          </details>
        {/each}
      </section>
    {/if}
  {:else}
    <p role="status">서버 권위 projection을 불러오는 중입니다.</p>
  {/if}
</div>

<style>
.business-health {
  display: grid;
  gap: 0.75rem;
}

.business-health-lead {
  margin: 0;
  padding: 0.625rem 0.75rem;
  border-left: 3px solid var(--amber-500);
  background: var(--amber-50);
  color: var(--ink-900);
  font-size: 0.875rem;
  line-height: 1.5;
}

.business-health-facts {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(12rem, 1fr));
  border-top: 1px solid var(--paper-200);
  border-left: 1px solid var(--paper-200);
}

.business-health-fact {
  min-width: 0;
  min-height: 3.25rem;
  padding: 0.5rem 0.625rem;
  border-right: 1px solid var(--paper-200);
  border-bottom: 1px solid var(--paper-200);
}

.business-health-fact dt,
.business-health-metric dt {
  color: var(--ink-500);
  font-size: 0.75rem;
  font-weight: 650;
}

.business-health-fact dd,
.business-health-metric dd {
  margin: 0.25rem 0 0;
  color: var(--ink-900);
  font-size: 0.875rem;
  line-height: 1.4;
  overflow-wrap: anywhere;
}

.business-health section {
  display: grid;
  gap: 0.5rem;
}

.business-health section h3 {
  margin: 0;
  font-size: 1rem;
  font-weight: 650;
}

.business-health-funnel {
  margin: 0;
  padding: 0;
  border-top: 1px solid var(--paper-200);
  list-style: none;
}

.business-health-funnel li {
  display: grid;
  grid-template-columns: minmax(10rem, 1fr) minmax(0, 1fr);
  align-items: center;
  gap: 0.75rem;
  min-height: 2.75rem;
  padding: 0.375rem 0.625rem;
  border-bottom: 1px solid var(--paper-200);
  font-size: 0.875rem;
  line-height: 1.4;
}

.business-health-funnel span {
  color: var(--ink-700);
}

.business-health-metric {
  border-bottom: 1px solid var(--paper-200);
}

.business-health-metric summary {
  display: flex;
  align-items: center;
  min-height: 2.75rem;
  padding: 0.375rem 0.625rem;
  color: var(--ink-900);
  font-size: 0.875rem;
  font-weight: 650;
  cursor: pointer;
}

.business-health-metric dl {
  margin: 0;
  border-top: 1px solid var(--paper-200);
}

.business-health-metric dl > div {
  display: grid;
  grid-template-columns: minmax(9rem, 0.8fr) minmax(0, 1.2fr);
  gap: 0.75rem;
  padding: 0.5rem 0.625rem;
  border-bottom: 1px solid var(--paper-200);
}

.business-health-metric dl > div:last-child {
  border-bottom: 0;
}

@media (max-width: 620px) {
  .business-health-facts {
    grid-template-columns: 1fr;
  }

  .business-health-funnel li,
  .business-health-metric dl > div {
    grid-template-columns: 1fr;
    gap: 0.25rem;
  }
}
</style>
