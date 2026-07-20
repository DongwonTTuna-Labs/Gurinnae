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
  // navigation. The heading remains keyboard reachable for repeat visits.
  requestAnimationFrame(() => receiptHeading?.focus());
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
