<script lang="ts">
import { tick } from "svelte";
import {
  donationActionErrorMessage,
  donationReceiptStatusLabel,
  type ScreenSectionProps,
} from "../../index";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime }: ScreenSectionProps = $props();
const donation = $derived(runtime.donation);
const queuedReceiptId = $derived(
  donation?.action.state === "QUEUED"
    ? donation.action.receipt.requestId
    : undefined,
);
let focusedReceiptId = $state<string>();
let receiptHeading = $state<HTMLHeadingElement>();

$effect(() => {
  const receiptId = queuedReceiptId;
  if (!receiptId || receiptId === focusedReceiptId) return;
  focusedReceiptId = receiptId;
  void tick().then(() => receiptHeading?.focus());
});
</script>

<SectionHeading {section} kicker="접수 영수증" />
{#if donation?.action.state === "QUEUED"}
  <h3 class="receipt-state-heading" tabindex="-1" bind:this={receiptHeading}>
    후원 요청 접수
  </h3>
  <p class="receipt-notice" role="status" aria-live="polite">
    테스트 후원 요청을 접수했습니다. 접수 대기는 결제 성공이 아니며, 결제
    제공자 재조회로 확정되기 전에는 후원 사실로 기록하지 않습니다.
  </p>
  <dl class="receipt-ledger">
    <div>
      <dt>상태</dt><dd>{donationReceiptStatusLabel(donation.action.receipt.status)}</dd>
    </div>
    <div><dt>요청 식별자</dt><dd>{donation.action.receipt.requestId}</dd></div>
    <div><dt>작업 식별자</dt><dd>{donation.action.receipt.jobId}</dd></div>
    <div>
      <dt>영수증 무결성 값</dt>
      <dd>{donation.action.receipt.receiptDigest}</dd>
    </div>
  </dl>
{:else if donation?.action.state === "ERROR"}
  <p class="receipt-error" role="alert">
    {donationActionErrorMessage(donation.action.code)}
  </p>
{:else}
  <p class="receipt-empty" role="status">아직 접수된 테스트 요청이 없습니다.</p>
{/if}

<style>
  .receipt-state-heading {
    margin: 0;
    padding: 0.5rem 0.625rem 0;
    color: var(--ink-950);
    font-size: 0.875rem;
    line-height: 1.4;
  }
  .receipt-state-heading:focus-visible {
    outline: 2px solid var(--blue-600);
    outline-offset: 2px;
  }
  .receipt-ledger {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 12rem), 1fr));
    gap: 1px;
    margin: 0;
    border-block: 1px solid var(--paper-200);
    background: var(--paper-200);
  }
  .receipt-ledger > div {
    min-width: 0;
    padding: 0.5rem 0.625rem;
    background: var(--paper-0);
  }
  dt {
    color: var(--ink-500);
    font-size: 0.75rem;
    font-weight: 650;
  }
  dd {
    margin: 0.125rem 0 0;
    color: var(--ink-900);
    font-size: 0.8125rem;
    font-weight: 650;
    overflow-wrap: anywhere;
  }
  .receipt-notice,
  .receipt-error,
  .receipt-empty {
    margin: 0;
    padding: 0.5rem 0.625rem;
    border-bottom: 1px solid var(--paper-200);
    font-size: 0.8125rem;
    line-height: 1.5;
  }
  .receipt-error {
    color: var(--red-700);
  }
</style>
