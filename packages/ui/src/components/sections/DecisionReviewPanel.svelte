<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import ApprovalDecisionDialog from "../ApprovalDecisionDialog.svelte";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, screen, runtime, projection }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="독립 검토" />
<div class="decision-gate" role="note">
  <strong>사람의 승인 필요</strong>
  <dl>
    <div><dt>승인 조건</dt><dd>현재 검토본 · 미해결 차단 사유 없음 · 독립성 · 추가 인증 상태 모두 충족</dd></div>
    <div><dt>결정 기록</dt><dd>승인·변경 요청·반려·회피 중 1개 · 사유</dd></div>
  </dl>
</div>
{#if section.id === "decision" || section.id === "decisions"}
  <!-- The decision dialog owns the screen-level action IDs. Preview and diff
       sections remain evidence-only so repeated panels cannot create duplicate
       controls or bypass the single approval path. -->
  <ApprovalDecisionDialog {screen} {runtime} dialogId={`decision-dialog-${screen.id.toLowerCase()}-${section.id.toLowerCase()}`} />
{/if}
{#if projection}<OperationData {runtime} {projection} mode="cards" emptyLabel="결정할 검토본이 없습니다." />{/if}

<style>
.decision-gate {
  display: grid;
  grid-template-columns: 9rem minmax(0, 1fr);
  align-items: start;
  gap: 0.75rem;
  margin-block: 0.75rem;
  padding: 0.625rem 0;
  border: 0;
  border-block: 1px solid var(--paper-200);
  border-radius: 0;
  background: transparent;
  font-size: 0.875rem;
}

.decision-gate > strong {
  color: var(--ink-900);
}

.decision-gate dl {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  margin: 0;
}

.decision-gate dl > div {
  min-width: 0;
  padding-inline: 0.625rem;
  border-left: 1px solid var(--paper-200);
}

.decision-gate dt {
  color: var(--ink-500);
  font-size: 0.75rem;
  font-weight: 650;
}

.decision-gate dd {
  margin: 0.25rem 0 0;
  color: var(--ink-700);
  font-size: 0.875rem;
  line-height: 1.4;
}

@media (max-width: 620px) {
  .decision-gate,
  .decision-gate dl {
    grid-template-columns: 1fr;
  }

  .decision-gate dl > div {
    padding: 0.5rem 0;
    border-top: 1px solid var(--paper-200);
    border-left: 0;
  }
}
</style>
