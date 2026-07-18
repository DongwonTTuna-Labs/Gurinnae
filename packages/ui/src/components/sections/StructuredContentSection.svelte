<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import { stateLabel, typedScreenViewModel } from "../../screen-contract";
import {
  type Int002Projection,
  toInt002ViewModel,
} from "../../view-models/int-002";
import OmnichannelApprovalPanel from "./OmnichannelApprovalPanel.svelte";
import BusinessHealthPanel from "./BusinessHealthPanel.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, screen, runtime, index }: ScreenSectionProps = $props();
const contract = $derived(typedScreenViewModel(screen));
const typedSection = $derived(
  contract.sections.find((item) => item.id === section.id),
);
const int002 = $derived(
  screen.id === "INT-002" ? toInt002ViewModel(runtime.data) : null,
);
const projection = $derived(int002 ? projectionFor(int002, section.id) : null);
const selectedTarget = $derived(int002?.selectedTarget ?? null);

function projectionFor(
  vm: ReturnType<typeof toInt002ViewModel>,
  sectionId: string,
): Int002Projection | null {
  if (sectionId === "views") return vm.viewsObject;
  if (sectionId === "tasks")
    return mergeProjection(vm.tasksAnswer, vm.tasksNextAction);
  if (sectionId === "handoff")
    return mergeProjection(
      vm.handoffState,
      vm.handoffEvidence,
      vm.handoffUnknown,
    );
  return null;
}

function mergeProjection(...items: Int002Projection[]): Int002Projection {
  const first =
    items[0] ??
    ({
      summary: "확인할 내용이 없습니다.",
      facts: [],
      status: "EMPTY",
      asOf: null,
      provenance: "none",
    } satisfies Int002Projection);
  return {
    ...first,
    summary: items.map((item) => item.summary).join(" · "),
    facts: items.flatMap((item) => item.facts),
    status: items.some((item) => item.status === "REVIEW_REQUIRED")
      ? "REVIEW_REQUIRED"
      : first.status,
  };
}
</script>

<SectionHeading {section} kicker={typedSection?.region === "next-action" ? "다음 단계" : "확인할 내용"} />
{#if screen.id === "OPS-004" && section.id === "business-health"}
  <BusinessHealthPanel {section} {screen} {runtime} index={index ?? 0} />
{:else}
<div class="structured-content" data-region={typedSection?.region ?? "state"} aria-busy={runtime.state === "loading"}>
  <p>{section.purpose}</p>
  <p class="structured-state" aria-live="polite">현재 상태: {stateLabel(runtime.state)} · 화면은 서버 권위 projection만 표시합니다.</p>
  {#if projection}
    <div class="typed-projection" data-testid={`${section.test_id}__typed-projection`}>
      <p class="projection-summary">{projection.summary}</p>
      {#if selectedTarget && section.id === "handoff"}
        <aside class="selected-target" aria-label="선택된 승인 대상">
          <strong>선택된 대상</strong>
          <span>{selectedTarget.proposalId} · v{selectedTarget.expectedProposalVersion}</span>
          <small>approval digest: {selectedTarget.expectedApprovalDigest}</small>
          {#if !selectedTarget.digestCurrent}<p role="alert">최신 지문과 일치하지 않아 승인이 차단되었습니다.</p>{/if}
        </aside>
      {/if}
      {#if projection.facts.length > 0}
        <dl class="structured-fields" aria-label={`${section.title}의 확인된 항목`}>
          {#each projection.facts as item}<div><dt>{item.label}</dt><dd>{#if item.href}<a href={item.href}>{item.value}</a>{:else}{item.value}{/if}{item.unit ? ` ${item.unit}` : ""}{#if item.uncertainty}<small class="field-uncertainty"> · {item.uncertainty}</small>{/if}</dd></div>{/each}
        </dl>
      {:else}<p class="empty-message" role="status">현재 계약에서 확인 가능한 항목이 없습니다.</p>{/if}
      <p class="projection-provenance">근거: {projection.provenance}{projection.asOf ? ` · 기준 시각 ${projection.asOf}` : ""}</p>
    </div>
  {:else if runtime.state === "loading"}<p role="status">서버가 확인한 내용을 불러오는 중입니다.</p>
  {:else if runtime.state === "empty"}<p role="status">이 범위에 확인할 기록이 아직 없습니다.</p>
  {:else if runtime.state === "error"}<p role="alert">이 영역을 확인하지 못했습니다. 오류 내용을 확인한 뒤 안전하게 다시 시도하세요.</p>
  {:else if runtime.state === "forbidden"}<p role="alert">현재 권한으로는 이 영역을 열 수 없습니다.</p>
  {:else if runtime.state === "stale"}<p role="status">표시된 projection이 오래되었습니다. 새로고침 후 결정을 계속하세요.</p>{/if}
</div>
{/if}
{#if screen.id === "INT-002" && section.id === "handoff"}
  <OmnichannelApprovalPanel {section} {screen} {runtime} {index} embedded />
{/if}
