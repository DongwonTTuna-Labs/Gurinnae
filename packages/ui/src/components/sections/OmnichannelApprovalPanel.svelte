<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import ApprovalDecisionDialog from "../ApprovalDecisionDialog.svelte";
import SectionHeading from "./SectionHeading.svelte";

type ApprovalField = { label: string; value: string; missing?: boolean };
type ApprovalCard = {
  proposalId: string;
  actionKind: string;
  version: string;
  contentDigest: string;
  approvalDigest: string;
  reason: string;
  risk: string;
  scope: string;
  body: string;
  attachments: string;
  consent: string;
  provider: string;
  endpoint: string;
  complete: boolean;
};

let {
  section,
  screen,
  runtime,
  embedded = false,
}: ScreenSectionProps & { embedded?: boolean } = $props();
const cards = $derived(parseQueue(runtime.data));
const runtimeState = $derived(runtime.state);
let selectedProposalId = $state(null as string | null);
const selectedTarget = $derived(asRecord(runtime.data.selectedTarget));
const selectedFromServer = $derived(text(selectedTarget?.proposalId));
const selectedCard = $derived(
  cards.find(
    (card) => card.proposalId === (selectedProposalId ?? selectedFromServer),
  ) ?? null,
);
const executionReceipt = $derived(
  asRecord(runtime.data.getActionExecutionReceipt),
);

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}
function text(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0
    ? value
    : typeof value === "number" || typeof value === "boolean"
      ? String(value)
      : null;
}
function field(value: unknown, empty = "미제공 — 승인 차단"): string {
  if (typeof value === "string" && value.trim()) return value;
  if (typeof value === "number" || typeof value === "boolean")
    return String(value);
  if (Array.isArray(value))
    return value.length > 0 ? `${value.length}개 항목` : "없음";
  return empty;
}
function digest(value: unknown): string {
  const valueText = text(value);
  return valueText && /^[0-9a-f]{64}$/.test(valueText)
    ? valueText
    : "미제공 — 승인 차단";
}
function attachmentSummary(value: unknown): string {
  if (!Array.isArray(value)) return field(value);
  const rows = value
    .map(asRecord)
    .filter((item): item is Record<string, unknown> => item !== null);
  if (rows.length === 0)
    return value.length === 0 ? "없음" : "첨부 checksum 미제공 — 승인 차단";
  const checksums = rows.map((row) =>
    text(row.checksum ?? row.sha256 ?? row.contentDigest),
  );
  return checksums.every(
    (item): item is string => item !== null && /^[0-9a-f]{64}$/.test(item),
  )
    ? checksums.join(" · ")
    : "첨부 checksum 미제공 — 승인 차단";
}
function parseQueue(data: Record<string, unknown>): ApprovalCard[] {
  const queue = asRecord(data.listActionApprovalQueue);
  const detail = asRecord(data.getActionProposal);
  const source =
    queue && Array.isArray(queue.items) ? queue.items : detail ? [detail] : [];
  return source
    .map(asRecord)
    .filter((item): item is Record<string, unknown> => item !== null)
    .flatMap((item) => {
      const proposal = asRecord(item.proposal) ?? item;
      const payload =
        asRecord(item.payload) ??
        asRecord(item.draft) ??
        asRecord(proposal.payload) ??
        {};
      const rationale =
        asRecord(item.rationale) ?? asRecord(proposal.rationale) ?? {};
      const target =
        asRecord(payload.target) ?? asRecord(proposal.target) ?? {};
      const communication =
        asRecord(payload.communication) ?? asRecord(item.communication) ?? {};
      const proposalId = text(proposal.proposalId);
      const version = text(proposal.version);
      if (!proposalId || !version) return [];
      const card: ApprovalCard = {
        proposalId,
        actionKind: field(proposal.actionKind),
        version,
        contentDigest: digest(proposal.contentDigest ?? item.contentDigest),
        approvalDigest: digest(proposal.approvalDigest ?? item.approvalDigest),
        reason: field(rationale.summary ?? item.reason),
        risk: field(rationale.riskNote ?? payload.risk ?? item.risk),
        scope: field(target.targetId ?? target.scope ?? payload.scope),
        body: field(
          payload.body ??
            payload.message ??
            payload.content ??
            communication.body,
        ),
        attachments: attachmentSummary(
          payload.attachments ?? communication.attachments,
        ),
        consent: field(
          payload.consent ??
            payload.publicationConsent ??
            communication.consent,
        ),
        provider: field(
          communication.provider ?? payload.provider ?? item.provider,
        ),
        endpoint: field(
          communication.endpoint ??
            communication.endpointId ??
            payload.endpoint ??
            item.endpoint,
        ),
        complete: [
          proposal.contentDigest ?? item.contentDigest,
          proposal.approvalDigest ?? item.approvalDigest,
          rationale.summary ?? item.reason,
          payload.body ??
            payload.message ??
            payload.content ??
            communication.body,
          payload.consent ??
            payload.publicationConsent ??
            communication.consent,
          communication.provider ?? payload.provider ?? item.provider,
          communication.endpoint ??
            communication.endpointId ??
            payload.endpoint ??
            item.endpoint,
        ].every((value) => text(value) !== null),
      };
      return [card];
    });
}
</script>

{#if !embedded}<SectionHeading {section} kicker="외부 전달 승인" />{/if}
<div class="omnichannel-approval" data-testid="omnichannel-approval" data-state={runtimeState} aria-busy={runtimeState === "loading"}>
  <p>외부 채널 전송은 사람의 명시적 승인과 정확한 payload·수신자·동의·provider receipt가 모두 확인될 때만 열립니다. 승인 전에는 어떤 채널에도 전송하지 않습니다.</p>
  {#if cards.length === 0}
    <p class="empty-message" role={runtimeState === "error" ? "alert" : "status"}>승인 가능한 typed proposal이 없습니다. 목록과 최신 상태를 다시 확인하세요.</p>
  {:else}
    <div class="approval-card-grid">
      {#each cards as card (card.proposalId)}
        <article class:selected={selectedCard?.proposalId === card.proposalId} class="approval-card" data-proposal-id={card.proposalId} aria-labelledby={`approval-${card.proposalId}`}>
          <header><h3 id={`approval-${card.proposalId}`}>외부 전달 제안</h3><span class="badge neutral">{card.actionKind}</span></header>
          <a class="secondary-button proposal-select" aria-current={selectedCard?.proposalId === card.proposalId ? "true" : undefined} href={`?proposalId=${encodeURIComponent(card.proposalId)}#${section.test_id}`}>이 제안 상세 확인</a>
          <dl class="approval-fields">
            <div><dt>proposal</dt><dd>{card.proposalId}</dd></div>
            <div><dt>version</dt><dd>{card.version}</dd></div>
            <div><dt>content digest</dt><dd>{card.contentDigest}</dd></div>
            <div><dt>approval digest</dt><dd>{card.approvalDigest}</dd></div>
            <div><dt>왜 보내는가</dt><dd>{card.reason}</dd></div>
            <div><dt>위험</dt><dd>{card.risk}</dd></div>
            <div><dt>범위·대상</dt><dd>{card.scope}</dd></div>
            <div><dt>본문</dt><dd class="preformatted">{card.body}</dd></div>
            <div><dt>첨부 checksum</dt><dd>{card.attachments}</dd></div>
            <div><dt>consent</dt><dd>{card.consent}</dd></div>
            <div><dt>provider</dt><dd>{card.provider}</dd></div>
            <div><dt>endpoint</dt><dd>{card.endpoint}</dd></div>
          </dl>
          {#if !card.complete}<p class="inline-state conflict" role="alert">필수 승인 정보가 누락되어 이 proposal은 승인할 수 없습니다.</p>{/if}
          {#if selectedCard?.proposalId === card.proposalId}<p class="selected-proposal-note" role="status">선택됨 · 서버가 다시 확인한 version/digest에만 결정을 결속합니다.</p>{/if}
        </article>
      {/each}
    </div>
  {/if}
  {#if runtimeState === "receipt"}<p class="inline-state" role="status">전달 영수증이 저장되었습니다. 동일한 내용은 receipt 확인 전 재전송하지 않습니다.</p>
  {:else if runtimeState === "conflict"}<p class="inline-state conflict" role="alert">승인 대상 버전이 바뀌었습니다. 기존 결정을 재사용하지 않고 새 preview를 확인해야 합니다.</p>
  {:else if runtimeState === "stale"}<p class="inline-state stale" role="status">승인 projection이 오래되었습니다. 새 digest와 version을 다시 확인하세요.</p>{/if}
  {#if executionReceipt}
    <section class="execution-receipt" aria-labelledby="int-002-execution-receipt-heading" data-testid="int_002__execution_receipt">
      <h3 id="int-002-execution-receipt-heading">실행 영수증</h3>
      <p role="status">서버가 확인한 실행 상태와 외부 효과를 다시 대조했습니다.</p>
      <dl class="approval-fields">
        <div><dt>종료 여부</dt><dd>{executionReceipt.terminal === true ? "종료" : "진행 중"}</dd></div>
        <div><dt>대조 필요</dt><dd>{executionReceipt.reconciliationRequired === true ? "필요" : "없음"}</dd></div>
        {#if Array.isArray(executionReceipt.receipts)}<div><dt>영수증 수</dt><dd>{executionReceipt.receipts.length}</dd></div>{/if}
      </dl>
    </section>
  {/if}
  {#if selectedCard && selectedTarget?.loadState === "READY"}
    <ApprovalDecisionDialog {screen} {runtime} dialogId={`approval-decision-${screen.id.toLowerCase()}`} />
  {:else if selectedCard}
    <p class="inline-state conflict" role="alert">제안 상세·version·승인 지문을 서버에서 확인하기 전에는 결정을 기록할 수 없습니다.</p>
  {/if}
</div>
