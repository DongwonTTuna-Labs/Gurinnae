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
  <p>외부 채널 전송은 사람의 명시적 승인과 정확한 payload·수신자·동의·영수증이 모두 확인될 때만 열립니다. 승인 전에는 전송하지 않습니다.</p>
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
  {#if projection}<OperationData {runtime} {projection} mode="cards" emptyLabel="승인 가능한 서버 권위 proposal이 없습니다." />{:else}<p role="status">승인 projection을 불러오는 중입니다.</p>{/if}
  {#if selectedTarget && !canDecide}<p class="inline-state conflict" role="status">제안 버전 또는 승인 지문이 최신이 아니어서 결정을 기록할 수 없습니다.</p>{/if}
  {#if canDecide}
    <p class="selected-proposal-note" role="status">서버가 확인한 proposal과 버전에 결속되었습니다. 결정 사유를 입력하세요.</p>
    <ApprovalDecisionDialog {screen} {runtime} dialogId={`approval-decision-${screen.id.toLowerCase()}`} />
  {/if}
  {#if runtime.state === "receipt"}<p class="inline-state" role="status">전달 영수증이 저장되었습니다. 같은 내용은 receipt 확인 전 재전송하지 않습니다.</p>
  {:else if runtime.state === "conflict"}<p class="inline-state conflict" role="status">승인 대상 버전이 바뀌었습니다. 새 preview를 확인해야 합니다.</p>
  {:else if runtime.state === "stale"}<p class="inline-state stale" role="status">승인 projection이 오래되었습니다. 새 digest와 version을 다시 확인하세요.</p>{/if}
</div>
