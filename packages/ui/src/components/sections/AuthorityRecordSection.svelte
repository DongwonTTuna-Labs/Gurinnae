<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import { typedScreenViewModel } from "../../screen-contract";
import SectionHeading from "./SectionHeading.svelte";

let {
  section,
  screen,
  runtime,
  projection,
  kicker = "확인할 내용",
}: ScreenSectionProps & { kicker?: string } = $props();
const contract = $derived(typedScreenViewModel(screen));
const typedSection = $derived(
  contract.sections.find((item) => item.id === section.id),
);
const declaredFields = $derived(typedSection?.fields ?? []);
const knownFields = $derived(
  projection?.fields.filter((field) => field.known && field.value !== null) ??
    [],
);
const stateMessage = $derived(
  projection?.errorMessage ??
    (projection?.state === "UNKNOWN"
      ? "현재 범위의 권위 데이터를 확인할 수 없습니다. 담당자가 근거와 기준 시각을 보완한 뒤 다시 시도하세요."
      : projection?.state === "STALE"
        ? "자료가 오래되어 최신 상태를 확인해야 합니다."
        : projection?.state === "ERROR"
          ? "자료를 불러오지 못했습니다. 잠시 후 다시 시도하세요."
          : null),
);
</script>

<SectionHeading {section} {kicker} />
<section class="authority-record-section" data-testid={section.test_id} data-region={projection?.region ?? typedSection?.region ?? "state"} data-projection-state={projection?.state} aria-busy={runtime.state === "loading"}>
  {#if projection?.state === "BLOCKED" || projection?.state === "UNKNOWN" || projection?.state === "ERROR" || projection?.state === "STALE"}
    <p class="inline-state conflict" role="status">{stateMessage ?? "필수 확인이 끝나지 않아 이 영역을 표시하지 않습니다."}</p>
  {:else if knownFields.length > 0}
    <dl class="semantic-facts" aria-label={`${section.title} 계약 필드`}>
      {#each knownFields as field}<div><dt>{field.label}</dt><dd>{field.value}</dd></div>{/each}
    </dl>
  {:else if projection && projection.state !== "EMPTY"}
    <p class="inline-state conflict" role="status">현재 범위의 권위 데이터가 비어 있습니다. 담당자가 근거를 보완한 뒤 다시 확인해야 합니다.</p>
  {:else if !projection}
    <p class="inline-state conflict" role="status">서버 권위 projection이 없어 이 영역을 표시할 수 없습니다.</p>
  {/if}
  {#if projection?.state === "LOADING" || runtime.state === "loading"}<p role="status">확인된 내용을 불러오는 중입니다.</p>
  {:else if runtime.state === "error"}<p role="status">이 영역을 확인하지 못했습니다. 잠시 후 다시 시도하세요.</p>
  {:else if runtime.state === "forbidden" || runtime.state === "unauthorized"}<p role="status">현재 권한으로는 이 영역을 열 수 없습니다.</p>
  {:else if runtime.state === "empty" || declaredFields.length === 0}<p role="status">이 범위에 확인 가능한 기록이 없습니다.</p>
  {:else if runtime.state === "stale" || runtime.state === "partial"}<p class="inline-state stale" role="status">일부 정보가 오래되었거나 누락되었습니다. 최신 상태를 확인하세요.</p>{/if}
</section>
