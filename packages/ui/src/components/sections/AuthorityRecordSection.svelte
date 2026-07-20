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
</script>

<SectionHeading {section} {kicker} />
<section class="authority-record-section" data-testid={section.test_id} data-region={projection?.region ?? typedSection?.region ?? "state"} data-projection-state={projection?.state} aria-busy={runtime.state === "loading"}>
  {#if projection && projection.fields.length > 0}
    <dl class="semantic-facts" aria-label={`${section.title} 계약 필드`}>
      {#each projection.fields as field}<div><dt>{field.label}</dt><dd>{field.value ?? "확인 필요"}</dd></div>{/each}
    </dl>
  {:else if projection && projection.state !== "EMPTY"}
    <p class="inline-state conflict" role="alert">현재 범위의 권위 데이터가 비어 있습니다. 담당자가 근거를 보완한 뒤 다시 확인해야 합니다.</p>
  {:else if !projection}
    <p class="inline-state conflict" role="alert">서버 권위 projection이 없어 이 영역을 표시할 수 없습니다.</p>
  {/if}
  {#if projection?.state === "LOADING" || runtime.state === "loading"}<p role="status">확인된 내용을 불러오는 중입니다.</p>
  {:else if runtime.state === "error"}<p role="alert">이 영역을 확인하지 못했습니다. 잠시 후 다시 시도하세요.</p>
  {:else if runtime.state === "forbidden" || runtime.state === "unauthorized"}<p role="alert">현재 권한으로는 이 영역을 열 수 없습니다.</p>
  {:else if projection?.state === "BLOCKED"}<p class="inline-state conflict" role="alert">{projection.errorMessage ?? "필수 확인이 끝나지 않아 다음 단계가 차단되었습니다."}</p>
  {:else if runtime.state === "empty" || declaredFields.length === 0}<p role="status">이 범위에 확인 가능한 기록이 없습니다.</p>
  {:else if runtime.state === "stale" || runtime.state === "partial"}<p class="inline-state stale" role="status">일부 정보가 오래되었거나 누락되었습니다. 최신 상태를 확인하세요.</p>{/if}
</section>
