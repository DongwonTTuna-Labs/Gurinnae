<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import ApprovalDecisionDialog from "../ApprovalDecisionDialog.svelte";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, screen, runtime, projection }: ScreenSectionProps = $props();
const stages = ["수집", "분석", "인용 검증", "사람 검토", "근거 승격"] as const;
const budget = $derived(screen.id === "OPS-004");
</script>

<SectionHeading {section} kicker={budget ? "사업 상태·비용 근거" : "AI 조사 결과"} />
  {#if budget}
  <div class="business-health" data-testid="ops-004-agent-suggestion" data-state={projection?.state ?? "UNKNOWN"} aria-busy={runtime.state === "loading"}>
    <p class="business-health-lead">예산 판단은 모델·OCR·저장·전송 비용과 업무 가치 근거가 모두 있을 때만 확정합니다.</p>
    {#if projection}<OperationData {runtime} {projection} mode="cards" emptyLabel="예산 근거를 확인할 수 없습니다." />{:else}<p role="status">예산 projection을 불러오는 중입니다.</p>{/if}
  </div>
{:else}
  <p class="agent-warning">AI 결과는 자동으로 근거가 되지 않습니다. 실행이 종료되고 출처·정확한 위치·권리·중단 사유가 검증된 뒤 사람이 선택한 자료만 근거로 승격합니다.</p>
  <ol class="analysis-stages" aria-label="조사 결과 처리 단계">
    {#each stages as stage, index}<li class:active={runtime.state === "success" ? index <= 3 : index === 0}><span>{index + 1}</span><strong>{stage}</strong></li>{/each}
  </ol>
  <div class="analysis-guard" role="note"><strong>승격 전 확인</strong><ul><li>원본 revision·locator 고정</li><li>원문 재추출·인용 일치</li><li>권리·개인정보·불확실성 표시</li></ul></div>
  <ApprovalDecisionDialog {screen} {runtime} dialogId={`suggestion-dialog-${screen.id.toLowerCase()}-${section.id.toLowerCase()}`} />
  {#if runtime.state === "receipt"}<p class="inline-state" role="status">근거 승격 영수증이 저장되었습니다. 동일한 근거 버전이 사건 근거 표와 공개 미리보기에 연결됩니다.</p>{/if}
  {#if projection}<OperationData {runtime} {projection} mode="cards" emptyLabel="대기 중인 조사 결과가 없습니다." />{/if}
{/if}

<style>
.business-health {
  display: grid;
  gap: 0.75rem;
}

.business-health-lead,
.agent-warning {
  margin: 0;
  font-size: 0.875rem;
  line-height: 1.5;
}

.business-health-lead {
  padding-block: 0.5rem;
  border-block: 1px solid var(--paper-200);
  color: var(--ink-700);
}

.agent-warning {
  padding: 0.625rem 0.75rem;
  border-left: 3px solid var(--violet-500);
  border-radius: 0 var(--radius-sm) var(--radius-sm) 0;
  background: var(--violet-50);
  color: var(--ink-900);
}

.analysis-stages {
  display: grid;
  grid-template-columns: repeat(5, minmax(0, 1fr));
  margin: 0.75rem 0;
  padding: 0;
  border-block: 1px solid var(--paper-200);
  list-style: none;
}

.analysis-stages li {
  display: grid;
  grid-template-columns: 1.25rem minmax(0, 1fr);
  align-items: center;
  gap: 0.375rem;
  min-height: 2.75rem;
  padding: 0.375rem 0.5rem;
  border: 0;
  border-right: 1px solid var(--paper-200);
  color: var(--ink-500);
  font-size: 0.75rem;
  line-height: 1.3;
}

.analysis-stages li:last-child {
  border-right: 0;
}

.analysis-stages li.active {
  background: var(--violet-50);
  color: var(--ink-900);
}

.analysis-stages li span {
  display: grid;
  place-items: center;
  width: 1.25rem;
  height: 1.25rem;
  border: 1px solid var(--paper-200);
  border-radius: 50%;
  font-weight: 700;
}

.analysis-stages li.active span {
  border-color: var(--violet-500);
  color: var(--violet-500);
}

.analysis-guard {
  display: grid;
  grid-template-columns: 8rem minmax(0, 1fr);
  align-items: center;
  gap: 0.75rem;
  padding: 0.625rem 0;
  border: 0;
  border-block: 1px solid var(--paper-200);
  border-radius: 0;
  background: transparent;
  font-size: 0.875rem;
}

.analysis-guard ul {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 0.5rem;
  margin: 0;
  padding: 0;
  list-style: none;
}

.analysis-guard li {
  padding-left: 0.5rem;
  border-left: 1px solid var(--violet-500);
  color: var(--ink-700);
  line-height: 1.4;
}

@media (max-width: 620px) {
  .analysis-stages {
    grid-template-columns: repeat(5, minmax(7rem, 1fr));
    overflow-x: auto;
  }

  .analysis-guard {
    grid-template-columns: 1fr;
  }

  .analysis-guard ul {
    grid-template-columns: 1fr;
  }
}
</style>
