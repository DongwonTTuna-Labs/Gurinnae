<script lang="ts">
  import type { ScreenSectionProps } from "../../index";
  import { toOps004ViewModel } from "../../view-models/ops-004";
  import ApprovalDecisionDialog from "../ApprovalDecisionDialog.svelte";
  import OperationData from "../OperationData.svelte";
  import SectionHeading from "./SectionHeading.svelte";

  let { section, screen, runtime }: ScreenSectionProps = $props();
  const stages = ["수집", "분석", "인용 검증", "사람 검토", "근거 승격"] as const;
  const budget = $derived(screen.id === "OPS-004" ? toOps004ViewModel(runtime.data) : null);
  const metric = (id: string) => budget?.metrics.find((item) => item.metricId === id);
  const metricValue = (id: string, fallback = "확인 필요") => {
    const item = metric(id);
    if (!item || item.status !== "KNOWN") return item?.reasonCode === "SAMPLE_TOO_SMALL" ? "표본 부족" : fallback;
    const result = item.result;
    const value = result?.value ?? result?.rate ?? result?.ratio ?? result?.p90Hours;
    return value === null || value === undefined ? fallback : String(value);
  };
</script>

<SectionHeading {section} kicker={budget ? "Business Health · 비용 envelope" : "AI 조사 결과"} />
{#if budget}
  <div class="business-health" data-testid="ops-004-agent-suggestion" data-state={budget.projectionState} aria-busy={runtime.state === "loading"}>
    <p class="business-health-lead">모델·OCR·storage·egress 비용을 workload 가치와 함께 확인합니다. 숫자나 상태가 빠지면 예산 판단을 READY로 표시하지 않습니다.</p>
    <dl class="semantic-facts budget-envelope-facts" aria-label="Business Health evidence">
      <div><dt>사양 버전</dt><dd>{budget.specificationVersion ?? "미제공 — 계약 확인 필요"}</dd></div>
      <div><dt>metric catalog digest</dt><dd>{budget.metricCatalogDigest ?? "미제공 — 증거 확인 필요"}</dd></div>
      <div><dt>퍼널 / 지표</dt><dd>{budget.funnel.length} / {budget.metrics.length} (필수 8 / 25)</dd></div>
      <div><dt>미확인 source</dt><dd>{budget.unknownSourceCount ?? "미제공"}</dd></div>
      <div><dt>최상위 이슈</dt><dd>{typeof budget.topIssue?.issueCode === "string" ? budget.topIssue.issueCode : "확인 필요"}</dd></div>
      <div><dt>다음 검토</dt><dd>{budget.nextReviewAt ?? "미제공 — owner 확인 필요"}</dd></div>
      <div><dt>budget id</dt><dd>{budget.budgetId ?? "미제공 — 운영자 확인 필요"}</dd></div>
      <div><dt>version</dt><dd>{budget.budgetVersion ?? "미제공 — 운영자 확인 필요"}</dd></div>
      <div><dt>상태</dt><dd>{budget.status}</dd></div>
      <div><dt>기준 시각</dt><dd>{budget.asOf ?? "미제공 — 최신성 확인 필요"}</dd></div>
      <div><dt>daily limit / used</dt><dd>{budget.dailyLimit ?? "미제공"} / {budget.dailyUsed ?? "미제공"}</dd></div>
      <div><dt>monthly limit / used</dt><dd>{budget.monthlyLimit ?? "미제공"} / {budget.monthlyUsed ?? "미제공"}</dd></div>
      <div><dt>provider</dt><dd>{budget.providers.length > 0 ? budget.providers.join(" · ") : "미제공"}</dd></div>
      <div><dt>workload</dt><dd>{budget.workloads.length > 0 ? budget.workloads.join(" · ") : "미제공"}</dd></div>
    </dl>
    <div class="health-grid" aria-label="핵심 상업 지표">
      <article><span>첫 유료 가치</span><strong>{metricValue("BM-VALUE-PAID-MVW")}</strong></article>
      <article><span>7일 활성화</span><strong>{metricValue("BM-ACTIVATION-7D-RATE")}</strong></article>
      <article><span>29–56일 유지</span><strong>{metricValue("BM-RETENTION-D29-56-RATE")}</strong></article>
      <article><span>인식 매출 (KRW)</span><strong>{metricValue("BM-REVENUE-RECOGNIZED-KRW")}</strong></article>
      <article><span>공헌 마진 (KRW)</span><strong>{metricValue("BM-MARGIN-CONTRIBUTION-KRW")}</strong></article>
      <article><span>지원 capacity</span><strong>{metricValue("BM-SUPPORT-HOURS-PER-ACTIVATED-ORG")}</strong></article>
    </div>
    {#if budget.summary}<p class="projection-summary">forecast: {budget.summary}</p>{/if}
    {#if budget.projectionState !== "READY" || runtime.state === "stale" || runtime.state === "partial"}
      <p class="inline-state stale" role="status">예산 projection이 불완전하거나 오래되었습니다. 비용·수익 판단을 확정하지 마세요.</p>
    {/if}
    {#if runtime.state === "error"}<p class="inline-state conflict" role="alert">예산 계산을 완료하지 못했습니다. false-green 상태를 표시하지 않습니다.</p>{/if}
  </div>
{:else}
  <p class="agent-warning">AI 결과는 자동으로 근거가 되지 않습니다. 실행이 종료되고 출처·정확한 위치·권리·중단 사유가 검증된 뒤 사람이 선택한 자료만 근거로 승격합니다.</p>
  <ol class="analysis-stages" aria-label="조사 결과 처리 단계">
    {#each stages as stage, index}<li class:active={runtime.state === "success" ? index <= 3 : index === 0}><span>{index + 1}</span><strong>{stage}</strong></li>{/each}
  </ol>
  <div class="analysis-guard" role="note"><strong>승격 전 확인</strong><ul><li>사용한 원본 revision과 locator가 고정되어 있는가</li><li>인용 내용이 원문에서 재추출되어 일치하는가</li><li>권리·개인정보·불확실성이 표시되어 있는가</li></ul></div>
  <ApprovalDecisionDialog {screen} {runtime} dialogId={`suggestion-dialog-${screen.id.toLowerCase()}-${section.id.toLowerCase()}`} />
  {#if runtime.state === "receipt"}<p class="inline-state" role="status">근거 승격 영수증이 저장되었습니다. 동일한 근거 버전이 사건 근거 표와 공개 미리보기에 연결됩니다.</p>{/if}
  <OperationData {runtime} mode="cards" emptyLabel="대기 중인 조사 결과가 없습니다." />
{/if}
