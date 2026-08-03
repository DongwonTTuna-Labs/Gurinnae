<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, screen, runtime, projection }: ScreenSectionProps = $props();
const showStateCopy = $derived(
  screen.sections.find((candidate) => candidate.component === "DataCollection")
    ?.id === section.id,
);
const blocking = $derived(
  projection &&
    ["BLOCKED", "UNKNOWN", "ERROR", "STALE", "LOADING"].includes(
      projection.state,
    ),
);
const stateCopy = $derived(
  projection?.state === "BLOCKED"
    ? "필수 확인이 끝나지 않아 목록을 표시하지 않습니다. 권한·승인 상태를 확인하세요."
    : projection?.state === "UNKNOWN"
      ? "현재 범위의 데이터를 확인할 수 없습니다. 담당자가 근거와 기준 시각을 보완해야 합니다."
      : projection?.state === "ERROR"
        ? "목록을 불러오지 못했습니다. 연결을 확인한 뒤 다시 시도하세요."
        : projection?.state === "STALE"
          ? "목록이 오래되었습니다. 최신 상태를 확인한 뒤 다시 시도하세요."
          : projection?.state === "LOADING"
            ? "확인된 목록을 불러오는 중입니다."
            : null,
);
</script>
<SectionHeading {section} kicker="기록" />
<section class="data-collection" data-testid={section.test_id} data-projection-state={projection?.state ?? "UNKNOWN"} aria-busy={runtime.state === "loading"}>
  {#if blocking}
    {#if showStateCopy}<p class="inline-state conflict" role={projection?.state === "ERROR" || projection?.state === "BLOCKED" ? "alert" : "status"} aria-live="polite">{stateCopy}</p>{/if}
  {:else if projection}
    <OperationData {runtime} {projection} mode="table" emptyLabel="현재 범위에 확인 가능한 기록이 없습니다." />
  {:else}
    <p class="inline-state conflict" role="status">목록을 표시할 수 없습니다. 잠시 후 다시 시도하세요.</p>
  {/if}
</section>

<style>
  .data-collection {
    display: grid;
    gap: 0.625rem;
    min-width: 0;
  }

  .inline-state {
    display: flex;
    gap: 0.5rem;
    align-items: flex-start;
    margin: 0;
    padding: 0.5rem 0.625rem;
    border-block: 1px solid var(--paper-200);
    background: var(--paper-50);
    color: var(--ink-700);
    font-size: 0.875rem;
    line-height: 1.4;
  }

  .inline-state::before {
    width: 0.45rem;
    height: 0.45rem;
    flex: 0 0 auto;
    margin-top: 0.4em;
    border-radius: 50%;
    background: var(--blue-500);
    content: "";
  }

  [data-projection-state="BLOCKED"] .inline-state,
  [data-projection-state="ERROR"] .inline-state {
    border-color: var(--red-500);
    background: var(--red-50);
    color: var(--red-900);
  }

  [data-projection-state="BLOCKED"] .inline-state::before,
  [data-projection-state="ERROR"] .inline-state::before {
    background: var(--red-500);
  }

  [data-projection-state="UNKNOWN"] .inline-state,
  [data-projection-state="STALE"] .inline-state {
    border-color: var(--amber-500);
    background: var(--amber-50);
    color: var(--amber-900);
  }

  [data-projection-state="UNKNOWN"] .inline-state::before,
  [data-projection-state="STALE"] .inline-state::before {
    background: var(--amber-500);
  }

  @media (forced-colors: active) {
    .inline-state {
      border-color: CanvasText;
      background: Canvas;
      color: CanvasText;
    }
  }
</style>
