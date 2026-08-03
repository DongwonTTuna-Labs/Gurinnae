<script lang="ts">
import {
  DONATION_INDEPENDENCE_NOTICE,
  DONATION_PUBLIC_ACCESS_NOTICE,
  type ScreenSectionProps,
} from "../../index";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime }: ScreenSectionProps = $props();
const donation = $derived(runtime.donation);
const offer = $derived(
  donation?.offer.state === "READY" ? donation.offer : undefined,
);
const unavailableReason = $derived(
  donation?.offer.state === "UNAVAILABLE"
    ? donation.offer.reason
    : "승인된 후원 구성이 없어 요청을 받지 않습니다.",
);
const operatingStateLabel = $derived(
  offer ? "테스트 모드 · 운영 사용 불가" : "운영 사용 불가",
);
const amountAuthorityLabel = $derived(
  offer ? "테스트 픽스처 전용 · 운영 금액 기준 없음" : "승인된 운영 금액 없음",
);
const productionReadinessLabel = $derived(
  offer ? "운영 준비도에 영향 없음" : "영향 없음",
);
</script>

{#if section.id === "mode"}
  <SectionHeading {section} kicker="작동 범위" />
  <dl class="status-ledger" aria-label="후원 작동 상태">
    <div>
      <dt>상태</dt>
      <dd>
        <span
          class:ready={offer !== undefined}
          class="status-dot"
          aria-hidden="true"
        ></span>
        {operatingStateLabel}
      </dd>
    </div>
    <div>
      <dt>금액 기준</dt>
      <dd>{amountAuthorityLabel}</dd>
    </div>
    <div>
      <dt>운영 준비도 영향</dt>
      <dd>{productionReadinessLabel}</dd>
    </div>
  </dl>
  <p class="mode-notice" role="status">
    {offer
      ? "테스트 모드 — 실제 결제·정기 청구·환불은 발생하지 않습니다."
      : unavailableReason}
  </p>
{:else}
  <SectionHeading {section} kicker="독립성" />
  <div class="independence-ledger">
    <strong>{DONATION_INDEPENDENCE_NOTICE}</strong>
    <p>{DONATION_PUBLIC_ACCESS_NOTICE}</p>
    <p>
      후원 성공·실패·취소·환불은 탐지·조사·편집·정정·공개 접근을
      변경하지 않습니다.
    </p>
  </div>
{/if}

<style>
  .status-ledger {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 12rem), 1fr));
    gap: 1px;
    margin: 0;
    border-block: 1px solid var(--paper-200);
    background: var(--paper-200);
  }
  .status-ledger > div {
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
  .status-dot {
    display: inline-block;
    width: 0.5rem;
    height: 0.5rem;
    margin-right: 0.35rem;
    border-radius: 50%;
    background: var(--red-600);
  }
  .status-dot.ready {
    background: var(--blue-600);
  }
  .mode-notice,
  .independence-ledger p {
    margin: 0;
    font-size: 0.8125rem;
    line-height: 1.5;
  }
  .mode-notice {
    padding: 0.5rem 0.625rem;
    border-bottom: 1px solid var(--paper-200);
  }
  .independence-ledger {
    display: grid;
    gap: 0.375rem;
    padding: 0.625rem;
    border-block: 1px solid var(--paper-200);
  }
  .independence-ledger strong {
    color: var(--ink-950);
    font-size: 0.9375rem;
  }
  .independence-ledger p {
    color: var(--ink-700);
  }
</style>
