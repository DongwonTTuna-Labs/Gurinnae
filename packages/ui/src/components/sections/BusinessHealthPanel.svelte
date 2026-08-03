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
    ? "서버가 확인한 상업 지표입니다. 기준 시각과 근거 지문을 함께 확인하세요."
    : (projection?.errorMessage ??
        "수익·비용·유지 지표를 확정할 수 없습니다. 누락된 근거를 먼저 보완하세요."),
);
</script>

<SectionHeading {section} kicker="사업 상태" />
<div class="business-health" data-testid="business-health-vm" data-state={projection?.state ?? "UNKNOWN"}>
  <p class="business-health-lead">현재 수익화 단계, 가장 큰 미확인, 다음 조치를 한 화면에서 확인합니다. AI 제안이나 페이지 조회만으로 유료 가치를 확정하지 않습니다.</p>
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
