<script lang="ts">
import { onMount } from "svelte";
import type { ScreenRuntime, ScreenSectionProjection } from "../../index";

let {
  runtime,
  projection,
}: { runtime: ScreenRuntime; projection?: ScreenSectionProjection } = $props();

type Receipt = {
  terminal: boolean;
  reconciliationRequired: boolean;
  destination: string | null;
  deliveryState: string | null;
};

const receipt = $derived.by<Receipt | null>(() => {
  const fields = projection?.fields ?? [];
  const value = (name: string): string | null => {
    const field = fields.find((item) => item.name === name && item.known);
    return typeof field?.value === "string" ? field.value : null;
  };
  return {
    terminal: value("receipt.terminal") === "true",
    reconciliationRequired: value("receipt.reconciliation_required") === "true",
    destination: value("receipt.destination"),
    deliveryState: value("receipt.delivery_state"),
  };
});

let receiptHeading: HTMLHeadingElement;
onMount(() => {
  // Returning from the step-up callback must put the user's attention on
  // the persisted outcome, not leave focus on the hidden authorization
  // navigation. SvelteKit restores route focus during initial hydration, so
  // wait for that frame before moving focus to the persisted receipt.
  requestAnimationFrame(() =>
    requestAnimationFrame(() => receiptHeading?.focus()),
  );
});
</script>

<section
  class="execution-receipt"
  data-testid="int_002__execution_receipt"
  data-focus-target="int_002__execution_receipt_heading"
  aria-labelledby="int_002__execution_receipt_heading"
  aria-live="polite"
>
  <h3 id="int_002__execution_receipt_heading" tabindex="-1" bind:this={receiptHeading}>전달 실행 영수증</h3>
  {#if receipt}
    <dl>
      <div><dt>종료 여부</dt><dd>{receipt.terminal ? "예" : "아니오"}</dd></div>
      <div><dt>재조정 필요</dt><dd>{receipt.reconciliationRequired ? "예" : "아니오"}</dd></div>
      <div><dt>수신자</dt><dd>{receipt.destination ?? "확인 필요"}</dd></div>
      <div><dt>전달 상태</dt><dd>{receipt.deliveryState ?? "확인 필요"}</dd></div>
    </dl>
  {:else}
    <p role="status">전달 실행 영수증을 확인하는 중입니다.</p>
  {/if}
</section>

<style>
  .execution-receipt {
    display: grid;
    min-width: 0;
    border-top: 2px solid var(--ink-900);
    border-bottom: 1px solid var(--paper-200);
  }

  h3 {
    margin: 0;
    padding: 0.625rem 0;
    font-size: var(--text-h2, 1.0625rem);
    font-weight: 650;
    line-height: 1.35;
  }

  dl {
    margin: 0;
    border-top: 1px solid var(--paper-200);
  }

  dl > div {
    display: grid;
    grid-template-columns: minmax(6.5rem, 0.4fr) minmax(0, 1fr);
    gap: 0.75rem;
    min-height: 2.75rem;
    padding: 0.5rem 0;
    border-top: 0;
    border-bottom: 1px solid var(--paper-200);
    align-items: baseline;
  }

  dl > div:last-child {
    border-bottom: 0;
  }

  dt {
    color: var(--ink-500);
    font-size: var(--text-meta, 0.75rem);
    font-weight: 650;
    line-height: 1.45;
  }

  dd {
    min-width: 0;
    margin: 0;
    font-size: var(--text-data, 0.875rem);
    line-height: 1.45;
    overflow-wrap: anywhere;
  }

  p[role="status"] {
    margin: 0;
    padding: 0.625rem 0;
    border-top: 1px solid var(--paper-200);
    color: var(--ink-700);
    font-size: var(--text-help, 0.8125rem);
    line-height: 1.5;
  }

  @media (max-width: 420px) {
    dl > div {
      grid-template-columns: minmax(5.75rem, 0.4fr) minmax(0, 1fr);
      gap: 0.5rem;
    }
  }
</style>
