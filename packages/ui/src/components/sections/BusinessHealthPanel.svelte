<script lang="ts">
  import type { ScreenSectionProps } from "../../index";
  import SectionHeading from "./SectionHeading.svelte";

  let { section, runtime }: ScreenSectionProps = $props();
  type Metric = { metricId?: string; status?: string; reasonCode?: string; result?: Record<string, unknown> };
  const envelope = $derived(record(runtime.data.getBudgetOverview));
  const health = $derived(record(envelope?.data ?? envelope));
  const metrics = $derived(array(health?.metrics).filter(isRecord) as Metric[]);
  const funnel = $derived(array(health?.funnel).filter(isRecord));
  const metric = (id: string): Metric | undefined => metrics.find((item) => item.metricId === id);
  const stage = (id: string): Record<string, unknown> | undefined => funnel.find((item) => item.stage === id);
  const metricLabel = (id: string, fallback: string): string => {
    const item = metric(id);
    if (!item) return fallback;
    if (item.status !== "KNOWN") return item.reasonCode === "SAMPLE_TOO_SMALL" ? "표본 부족" : "확인 필요";
    const value = item.result?.value ?? item.result?.rate ?? item.result?.ratio;
    return value === null || value === undefined ? fallback : String(value);
  };
  const readiness = $derived(typeof health?.readinessState === "string" ? health.readinessState : "확인 필요");
  const firstPaid = $derived(metricLabel("BM-VALUE-PAID-MVW", "확인 필요"));
  const activation = $derived(metricLabel("BM-ACTIVATION-7D-RATE", "확인 필요"));
  const retention = $derived(metricLabel("BM-RETENTION-D29-56-RATE", "확인 필요"));
  const risk = $derived(typeof health?.topIssue === "object" && health.topIssue !== null && "issueCode" in health.topIssue ? String((health.topIssue as Record<string, unknown>).issueCode) : "확인 필요");
  const qualified = $derived(stage("QUALIFIED")?.organizationCount ?? "확인 필요");
  const configured = $derived(stage("CONFIGURED")?.organizationCount ?? "확인 필요");
  const dataReady = $derived(stage("DATA_READY")?.organizationCount ?? "확인 필요");
  const atRisk = $derived(stage("AT_RISK")?.organizationCount ?? "확인 필요");
  const unknownCount = $derived(typeof health?.unknownSourceCount === "number" ? health.unknownSourceCount : "확인 필요");
  const digest = $derived(typeof health?.metricCatalogDigest === "string" ? health.metricCatalogDigest : "미제공");
  function array(value: unknown): unknown[] { return Array.isArray(value) ? value : []; }
  function record(value: unknown): Record<string, unknown> | null { return isRecord(value) ? value : null; }
  function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
</script>

<SectionHeading {section} kicker="Business Health" />
<div class="business-health" data-testid="business-health-vm">
  <p class="business-health-lead">지불 가능한 결과를 만들고 반복 사용으로 이어지는지 한눈에 확인합니다. AI 제안·페이지 조회·청구서만으로는 가치 달성으로 계산하지 않습니다.</p>
  <div class="health-grid">
    <article><span>현재 상업 상태</span><strong>{readiness}</strong><small>as-of와 evidence digest가 함께 고정됩니다</small></article>
    <article><span>첫 유료 가치</span><strong>{firstPaid}</strong><small>최종 packet·terminal receipt가 검증된 MVW</small></article>
    <article><span>7일 활성화</span><strong>{activation}</strong><small>DATA_READY부터 첫 유료 가치까지의 고정 창</small></article>
    <article><span>29–56일 유지</span><strong>{retention}</strong><small>성숙 cohort만 분모에 포함</small></article>
  </div>
  <dl class="business-health-funnel" aria-label="상업 퍼널">
    <div><dt>Qualified</dt><dd>{qualified}</dd></div>
    <div><dt>Configured</dt><dd>{configured}</dd></div>
    <div><dt>Data ready</dt><dd>{dataReady}</dd></div>
    <div class:risk-card={risk !== "NONE"}><dt>At risk / blocker</dt><dd>{atRisk} · {risk}</dd></div>
  </dl>
  <section class="business-health-metrics" aria-label="전체 business metric">
    <h3>근거가 연결된 지표</h3>
    <p class="metric-meta">unknown {unknownCount} · catalog digest {digest}</p>
    <div class="metric-table" role="list">
      {#each metrics as item (item.metricId)}
        <article role="listitem" class:metric-unknown={item.status !== "KNOWN"}>
          <strong>{item.metricId ?? "미명명 지표"}</strong>
          <span>{item.status ?? "UNKNOWN"} · {item.reasonCode ?? "SOURCE_MISSING"}</span>
          {#if item.result}<small>{String(item.result.value ?? item.result.rate ?? item.result.ratio ?? "값 없음")}</small>{/if}
          {#if item.status !== "KNOWN"}<small class="metric-owner">다음 확인: {item.reasonCode ?? "근거 보강"}</small>{/if}
        </article>
      {/each}
    </div>
  </section>
  {#if runtime.state === "partial" || runtime.state === "stale"}<p class="inline-state stale" role="status">일부 상업 지표가 오래되었거나 누락되었습니다. 현재 화면의 수익·유지 판단을 확정하지 마세요.</p>{/if}
  {#if runtime.state === "error"}<p class="inline-state conflict" role="alert">Business Health 계산을 완료하지 못했습니다. 비용·수익 상태를 임의로 READY로 표시하지 않습니다.</p>{/if}
</div>
