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
    <p class="business-health-lead">모델·OCR·저장·전송 비용과 업무 가치를 함께 확인합니다. 값이 빠지면 예산 판단을 확정하지 않습니다.</p>
    {#if projection}<OperationData {runtime} {projection} mode="cards" emptyLabel="예산 근거를 확인할 수 없습니다." />{:else}<p role="status">예산 projection을 불러오는 중입니다.</p>{/if}
  </div>
{:else}
  <p class="agent-warning">AI 결과는 자동으로 근거가 되지 않습니다. 실행이 종료되고 출처·정확한 위치·권리·중단 사유가 검증된 뒤 사람이 선택한 자료만 근거로 승격합니다.</p>
  <ol class="analysis-stages" aria-label="조사 결과 처리 단계">
    {#each stages as stage, index}<li class:active={runtime.state === "success" ? index <= 3 : index === 0}><span>{index + 1}</span><strong>{stage}</strong></li>{/each}
  </ol>
  <div class="analysis-guard" role="note"><strong>승격 전 확인</strong><ul><li>사용한 원본 revision과 locator가 고정되어 있는가</li><li>인용 내용이 원문에서 재추출되어 일치하는가</li><li>권리·개인정보·불확실성이 표시되어 있는가</li></ul></div>
  <ApprovalDecisionDialog {screen} {runtime} dialogId={`suggestion-dialog-${screen.id.toLowerCase()}-${section.id.toLowerCase()}`} />
  {#if runtime.state === "receipt"}<p class="inline-state" role="status">근거 승격 영수증이 저장되었습니다. 동일한 근거 버전이 사건 근거 표와 공개 미리보기에 연결됩니다.</p>{/if}
  {#if projection}<OperationData {runtime} {projection} mode="cards" emptyLabel="대기 중인 조사 결과가 없습니다." />{/if}
{/if}
