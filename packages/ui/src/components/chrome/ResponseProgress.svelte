<script lang="ts">
import { responseProgressStateForStep } from "../../screen-chrome";

let { responseStep, errorCount }: { responseStep: number; errorCount: number } =
  $props();
const responseStepLabels = [
  "요청 확인",
  "답변 작성",
  "첨부 검토",
  "제출 검토",
  "제출 완료",
];
</script>

{#if responseStep > 0}
  <ol class="progress" aria-label="보호된 소명 절차 진행률">
    {#each responseStepLabels as label, index}
      {@const step = index + 1}
      {@const stepState = responseProgressStateForStep(step, responseStep, errorCount)}
      <li class:active={step <= responseStep} data-step-state={stepState} aria-current={step === responseStep ? "step" : undefined}><span>{step}</span><span>{label}</span></li>
    {/each}
  </ol>
{/if}

<style>
.progress {
  margin: 0 0 18px;
  padding: 0;
  display: grid;
  grid-template-columns: repeat(5, minmax(0, 1fr));
  gap: 4px;
  list-style: none;
}

.progress li {
  min-height: 40px;
  padding: 5px 3px;
  display: grid;
  place-items: center;
  gap: 1px;
  border-top: 2px solid var(--paper-200);
  color: var(--ink-500);
  font-size: 0.75rem;
  line-height: 1.35;
  text-align: center;
}

.progress li span:first-child {
  font-weight: 700;
}

.progress li.active {
  border-color: var(--blue-700);
  color: var(--blue-900);
}

.progress li[data-step-state="error"] {
  border-color: var(--red-700);
  color: var(--red-700);
}

.progress li[data-step-state="not-started"] {
  color: var(--ink-500);
}

@media (max-width: 620px) {
  .progress {
    margin-bottom: 14px;
    gap: 2px;
  }

  .progress li {
    min-height: 44px;
    padding-inline: 1px;
  }
}
</style>
