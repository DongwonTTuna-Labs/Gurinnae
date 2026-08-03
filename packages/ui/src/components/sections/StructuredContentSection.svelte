<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import { stateLabel, typedScreenViewModel } from "../../screen-contract";
import OperationData from "../OperationData.svelte";
import ExecutionReceiptPanel from "./ExecutionReceiptPanel.svelte";
import OmnichannelApprovalPanel from "./OmnichannelApprovalPanel.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, screen, runtime, index, projection }: ScreenSectionProps =
  $props();
const contract = $derived(typedScreenViewModel(screen));
const typedSection = $derived(
  contract.sections.find((item) => item.id === section.id),
);
const sectionCopy = $derived(
  {
    envelope: "예산 기간 · 상태 · 통화",
    spend: "공급자 · 업무별 실제 사용량",
    forecast: "관측 사용량 · 예측 가정",
    limits: "소프트 한도 · 하드 한도 · 초과 동작",
    alerts: "임계값 초과 · 확인 필요",
    changes: "한도 변경 승인자 · 사유 · 시각",
  }[section.id] ?? section.purpose,
);
const loading = $derived(
  runtime.state === "loading" ||
    runtime.state === "initial-loading" ||
    projection?.state === "LOADING",
);
const initialAuth = $derived(
  screen.id === "AUTH-001" &&
    runtime.state === "unauthenticated" &&
    runtime.errors.length === 0,
);
const copyOnly = $derived(screen.id === "PUB-001" && section.id === "mission");
</script>

	<SectionHeading {section} kicker={typedSection?.region === "next-action" ? "다음 단계" : "확인할 내용"} />
	<div class="structured-content" data-region={projection?.region ?? typedSection?.region ?? "state"} data-projection-state={projection?.state ?? "UNKNOWN"} aria-busy={runtime.state === "loading"}>
	  {#if copyOnly || sectionCopy !== section.purpose}<p class="section-summary">{sectionCopy}</p>{/if}
	  {#if !initialAuth}<p class="structured-state"><span class="state-dot" aria-hidden="true"></span><span>현재 상태</span><strong>{stateLabel(runtime.state)}</strong></p>{/if}
	  {#if copyOnly}
	    <!-- PUB-001 mission is complete in its contracted copy; it has no data DTO. -->
	  {:else if initialAuth}
    <!-- The screen-level live guidance owns this expected pre-auth state. -->
  {:else if loading}
    <div class="skeleton-record" aria-label={`${section.title} 불러오는 중`} aria-hidden="true"><span></span><span></span><span></span></div>
    <p role="status">{section.title}의 확인된 값을 불러오는 중입니다.</p>
  {:else if projection}
    <OperationData {runtime} {projection} mode="cards" emptyLabel="현재 계약에서 확인 가능한 항목이 없습니다." />
  {:else}
    <p class="inline-state conflict" role="status">{section.title} 정보를 표시할 수 없습니다. 잠시 후 다시 시도하세요.</p>
  {/if}
</div>
{#if screen.id === "INT-002" && section.id === "handoff"}
  <OmnichannelApprovalPanel {section} {screen} {runtime} {index} {projection} embedded />
  {#if projection}<ExecutionReceiptPanel {runtime} {projection} />{/if}
{/if}

<style>
  .structured-content {
    display: grid;
    width: 100%;
    gap: var(--density-gap, 6px);
  }

  .structured-content p {
    margin: 0;
    font-size: 0.9375rem;
    line-height: 1.5;
  }

  .section-summary {
    max-width: 72ch;
    color: var(--ink-700);
  }

  .structured-state {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 5px 8px;
    padding-block: var(--density-row-block, 6px);
    border-block: 1px solid var(--paper-200);
    color: var(--ink-500);
  }

  .structured-state span {
    font-size: 0.75rem;
    font-weight: 650;
  }

  .structured-state strong {
    color: var(--ink-900);
    font-size: 0.8125rem;
  }

  .state-dot {
    width: 7px;
    height: 7px;
    flex: 0 0 auto;
    border-radius: 50%;
    background: var(--blue-500);
  }

  .structured-state {
    position: absolute;
    width: 1px;
    height: 1px;
    padding: 0;
    margin: -1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
    white-space: nowrap;
    border: 0;
  }

  .inline-state {
    padding: 9px 11px;
    border-inline-start: 3px solid var(--red-500);
    background: var(--red-50);
    color: var(--red-900);
  }

  @media (max-width: 620px) {
    .structured-content {
      gap: 8px;
    }
  }
</style>
