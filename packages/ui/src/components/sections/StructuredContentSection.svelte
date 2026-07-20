<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import { stateLabel, typedScreenViewModel } from "../../screen-contract";
import OperationData from "../OperationData.svelte";
import BusinessHealthPanel from "./BusinessHealthPanel.svelte";
import ExecutionReceiptPanel from "./ExecutionReceiptPanel.svelte";
import OmnichannelApprovalPanel from "./OmnichannelApprovalPanel.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, screen, runtime, index, projection }: ScreenSectionProps =
  $props();
const contract = $derived(typedScreenViewModel(screen));
const typedSection = $derived(
  contract.sections.find((item) => item.id === section.id),
);
</script>

{#if screen.id === "OPS-004" && section.id === "business-health"}
  <BusinessHealthPanel {section} {screen} {runtime} {index} {projection} />
{:else}
  <SectionHeading {section} kicker={typedSection?.region === "next-action" ? "다음 단계" : "확인할 내용"} />
  <div class="structured-content" data-region={projection?.region ?? typedSection?.region ?? "state"} data-projection-state={projection?.state ?? "UNKNOWN"} aria-busy={runtime.state === "loading"}>
    <p>{section.purpose}</p>
    <p class="structured-state">현재 상태: {stateLabel(runtime.state)} · 서버 권위 projection만 표시합니다.</p>
    {#if projection}
      <OperationData {runtime} {projection} mode="cards" emptyLabel="현재 계약에서 확인 가능한 항목이 없습니다." />
      <p class="projection-provenance">근거: 화면별 allowlist projection · 각 값의 출처 지문은 서버가 관리합니다.</p>
    {:else}
      <p role="status">서버 권위 projection을 불러오는 중입니다.</p>
    {/if}
  </div>
  {#if screen.id === "INT-002" && section.id === "handoff"}
    <OmnichannelApprovalPanel {section} {screen} {runtime} {index} {projection} embedded />
    {#if projection}<ExecutionReceiptPanel {runtime} {projection} />{/if}
  {/if}
{/if}
