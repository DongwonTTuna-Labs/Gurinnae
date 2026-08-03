<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import ApprovalDecisionDialog from "../ApprovalDecisionDialog.svelte";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let {
  section,
  screen,
  runtime,
  projection,
  embedded = false,
}: ScreenSectionProps & { embedded?: boolean } = $props();
const selectedTarget = $derived(runtime.selectedTarget);
const canDecide = $derived(
  selectedTarget?.loadState === "READY" && selectedTarget.digestCurrent,
);
// Once the proposal is approved, the handoff binding digest is the digest
// the reviewer must recognise for the next leg of the journey.  Before a
// handoff exists this intentionally falls back to the proposal approval
// digest used by submitActionDecision.
const displayedDigest = $derived(
  selectedTarget?.expectedBindingDigest ??
    selectedTarget?.expectedApprovalDigest,
);
</script>

{#if !embedded}<SectionHeading {section} kicker="외부 전달 승인" />{/if}
<div class="omnichannel-approval" data-testid="omnichannel-approval" data-state={projection?.state ?? "UNKNOWN"} aria-busy={runtime.state === "loading"}>
  <p class="approval-safety">외부 채널 전송은 사람의 명시적 승인과 정확한 payload·수신자·동의·영수증이 모두 확인될 때만 열립니다. 승인 전에는 전송하지 않습니다.</p>
  {#if runtime.approvalQueue && runtime.approvalQueue.length > 0}
    <div class="approval-queue" aria-label="승인 대기 제안">
      {#each runtime.approvalQueue as item (item.proposalId)}
        <article class="approval-queue-card" data-proposal-id={item.proposalId}>
          <div>
            <h3>외부 전달 제안</h3>
            <p>v{item.version} · {item.state}</p>
            <p class="digest">승인 지문 {item.approvalDigest}</p>
          </div>
          <a class="secondary-button" href={item.href}>이 제안 상세 확인</a>
        </article>
      {/each}
    </div>
  {/if}
  {#if selectedTarget}
    <div class="selected-approval-target" aria-label="선택된 승인 대상">
      <strong>{selectedTarget.proposalId}</strong>
      <span>v{selectedTarget.expectedProposalVersion}</span>
      <span>승인 지문 {displayedDigest}</span>
    </div>
  {/if}
  {#if projection}<OperationData {runtime} {projection} mode="cards" emptyLabel="승인 가능한 서버 권위 제안이 없습니다." />{:else}<p role="status">승인 투영값을 불러오는 중입니다.</p>{/if}
  {#if selectedTarget && !canDecide}<p class="inline-state conflict" role="status">제안 버전 또는 승인 지문이 최신이 아니어서 결정을 기록할 수 없습니다.</p>{/if}
  {#if canDecide}
    <p class="selected-proposal-note" role="status">서버가 확인한 제안과 버전에 결속되었습니다. 결정 사유를 입력하세요.</p>
    <ApprovalDecisionDialog {screen} {runtime} dialogId={`approval-decision-${screen.id.toLowerCase()}`} />
  {/if}
  {#if runtime.state === "receipt"}<p class="inline-state" role="status">전달 영수증이 저장되었습니다. 같은 내용은 receipt 확인 전 재전송하지 않습니다.</p>
  {:else if runtime.state === "conflict"}<p class="inline-state conflict" role="status">승인 대상 버전이 바뀌었습니다. 새 미리보기를 확인해야 합니다.</p>
  {:else if runtime.state === "stale"}<p class="inline-state stale" role="status">승인 투영값이 오래되었습니다. 새 지문과 버전을 다시 확인하세요.</p>{/if}
</div>

<style>
  .omnichannel-approval {
    display: grid;
    gap: 12px;
    min-width: 0;
  }

  .approval-safety {
    margin: 0;
    padding: 8px 10px;
    border-left: 3px solid var(--blue-500);
    background: var(--blue-50);
    color: var(--ink-900);
    font-size: 0.8125rem;
    line-height: 1.5;
  }

  .approval-queue {
    display: grid;
    border-top: 1px solid var(--paper-200);
  }

  .approval-queue-card {
    display: grid;
    grid-template-columns: minmax(0, 1fr) max-content;
    align-items: center;
    gap: 12px;
    padding: 7px 10px;
    border-bottom: 1px solid var(--paper-200);
  }

  .approval-queue-card > div {
    display: grid;
    grid-template-columns: minmax(7rem, 0.8fr) max-content minmax(12rem, 2fr);
    align-items: center;
    gap: 8px 12px;
    min-width: 0;
  }

  .approval-queue-card h3,
  .approval-queue-card p {
    margin: 0;
  }

  .approval-queue-card h3 {
    font-size: 0.875rem;
    font-weight: 650;
  }

  .approval-queue-card p,
  .approval-queue-card a {
    font-size: 0.75rem;
  }

  .approval-queue-card p {
    color: var(--ink-500);
    line-height: 1.4;
  }

  .approval-queue-card .digest {
    min-width: 0;
    overflow-wrap: anywhere;
    font-variant-numeric: tabular-nums;
  }

  .selected-approval-target {
    display: grid;
    grid-template-columns: minmax(8rem, 1fr) max-content minmax(12rem, 2fr);
    align-items: center;
    gap: 8px 16px;
    padding: 8px 10px;
    border-block: 1px solid var(--paper-200);
    font-size: 0.875rem;
    line-height: 1.4;
  }

  .selected-approval-target strong,
  .selected-approval-target span {
    min-width: 0;
    overflow-wrap: anywhere;
  }

  .selected-approval-target span {
    color: var(--ink-500);
    font-size: 0.75rem;
    font-variant-numeric: tabular-nums;
  }

  .selected-proposal-note,
  .inline-state,
  .omnichannel-approval > p[role="status"] {
    margin: 0;
    padding: 8px 10px;
    border-left: 3px solid var(--blue-500);
    background: var(--blue-50);
    font-size: 0.8125rem;
    line-height: 1.5;
  }

  .inline-state.conflict {
    border-color: var(--red-500);
    background: var(--red-50);
    color: var(--red-900);
  }

  .inline-state.stale {
    border-color: var(--amber-500);
    background: var(--amber-50);
    color: var(--amber-900);
  }

  @media (max-width: 760px) {
    .approval-queue-card {
      grid-template-columns: 1fr;
    }

    .approval-queue-card > div {
      grid-template-columns: minmax(7rem, 1fr) max-content;
    }

    .approval-queue-card .digest {
      grid-column: 1 / -1;
    }

    .approval-queue-card a {
      justify-self: start;
    }

    .selected-approval-target {
      grid-template-columns: minmax(8rem, 1fr) max-content;
    }

    .selected-approval-target span:last-child {
      grid-column: 1 / -1;
    }
  }

  @media (max-width: 420px) {
    .approval-queue-card > div,
    .selected-approval-target {
      grid-template-columns: 1fr;
    }

    .approval-queue-card .digest,
    .selected-approval-target span:last-child {
      grid-column: auto;
    }
  }

  @media (forced-colors: active) {
    .approval-safety,
    .approval-queue,
    .approval-queue-card,
    .selected-approval-target,
    .selected-proposal-note,
    .inline-state,
    .omnichannel-approval > p[role="status"] {
      border-color: CanvasText;
      background: Canvas;
      color: CanvasText;
    }
  }
</style>
