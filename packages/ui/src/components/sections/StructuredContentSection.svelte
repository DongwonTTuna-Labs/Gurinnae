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
    envelope: "예산 기간·상태·통화를 먼저 확인합니다.",
    spend: "공급자와 업무별 실제 사용량을 비교합니다.",
    forecast: "관측된 사용량과 예측 가정을 함께 확인합니다.",
    limits: "소프트·하드 한도와 초과 시 동작을 확인합니다.",
    alerts: "임계값을 넘었거나 확인이 필요한 경고입니다.",
    changes: "한도 변경의 승인자·사유·시각을 확인합니다.",
  }[section.id] ?? section.purpose,
);
const loading = $derived(
  runtime.state === "loading" ||
    runtime.state === "initial-loading" ||
    projection?.state === "LOADING",
);
</script>

<SectionHeading {section} kicker={typedSection?.region === "next-action" ? "다음 단계" : "확인할 내용"} />
<div class="structured-content" data-region={projection?.region ?? typedSection?.region ?? "state"} data-projection-state={projection?.state ?? "UNKNOWN"} aria-busy={runtime.state === "loading"}>
  <p>{sectionCopy}</p>
  <p class="structured-state">현재 상태: {stateLabel(runtime.state)} · 근거 시각과 미확인 범위를 함께 표시합니다.</p>
  {#if loading}
    <div class="skeleton-record" aria-label={`${section.title} 불러오는 중`} aria-hidden="true"><span></span><span></span><span></span></div>
    <p role="status">{section.title}의 확인된 값을 불러오는 중입니다.</p>
  {:else if projection}
    <OperationData {runtime} {projection} mode="cards" emptyLabel="현재 계약에서 확인 가능한 항목이 없습니다." />
    <p class="projection-provenance">근거: 화면별 allowlist projection · 각 값의 출처 지문은 서버가 관리합니다.</p>
  {:else}
    <p class="inline-state conflict" role="status">{section.title}의 권위 projection을 확인할 수 없습니다. 지원 담당자에게 화면 ID와 기준 시각을 전달하세요.</p>
  {/if}
</div>
{#if screen.id === "INT-002" && section.id === "handoff"}
  <OmnichannelApprovalPanel {section} {screen} {runtime} {index} {projection} embedded />
  {#if projection}<ExecutionReceiptPanel {runtime} {projection} />{/if}
{/if}
