<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, projection }: ScreenSectionProps = $props();
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
      ? "현재 범위의 권위 데이터를 확인할 수 없습니다. 담당자가 근거와 기준 시각을 보완해야 합니다."
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
    <p class="inline-state conflict" role={projection?.state === "ERROR" || projection?.state === "BLOCKED" ? "alert" : "status"} aria-live="polite">{stateCopy}</p>
  {:else if projection}
    <div class="collection-summary" role="status" aria-live="polite">
      <strong>{projection.fields.filter((field) => field.known && field.value !== null).length}개 항목 확인됨</strong>
      <span>각 항목은 서버 권위 projection의 최신 확인 결과입니다.</span>
    </div>
    <OperationData {runtime} {projection} mode="table" emptyLabel="현재 범위에 확인 가능한 기록이 없습니다." />
  {:else}
    <p class="inline-state conflict" role="status">서버 권위 projection이 없어 목록을 표시할 수 없습니다.</p>
  {/if}
</section>
