<script lang="ts">
  import type { ScreenSectionProps } from "../../index";
  import { display, semanticRecords, visibleEntries } from "../../data";
  import { humanFieldLabel, typedScreenViewModel } from "../../screen-contract";
  import SectionHeading from "./SectionHeading.svelte";

  let { section, screen, runtime, kicker = "확인할 내용" }: ScreenSectionProps & { kicker?: string } = $props();
  const contract = $derived(typedScreenViewModel(screen));
  const typedSection = $derived(contract.sections.find((item) => item.id === section.id));
  const records = $derived(semanticRecords(runtime));
  const entries = $derived(records.flatMap(({ record }) => visibleEntries(record)).slice(0, 24));
  const declaredFields = $derived(typedSection?.fields ?? []);

  function valueFor(field: string): string {
    const normalized = field.replace(/[^a-z0-9]/gi, "").toLowerCase();
    for (const { record } of records) {
      const match = Object.entries(record).find(([key]) => key.replace(/[^a-z0-9]/gi, "").toLowerCase() === normalized);
      if (match) return display(match[1]);
    }
    return "확인 필요";
  }
</script>

<SectionHeading {section} {kicker} />
<section class="authority-record-section" data-testid={section.test_id} data-region={typedSection?.region ?? "state"} aria-busy={runtime.state === "loading"}>
  {#if declaredFields.length > 0}
    <dl class="semantic-facts" aria-label={`${section.title} 계약 필드`}>
      {#each declaredFields as field}<div><dt>{humanFieldLabel(field)}</dt><dd>{valueFor(field)}</dd></div>{/each}
    </dl>
  {:else if entries.length > 0}
    <dl class="semantic-facts" aria-label={`${section.title} 확인 정보`}>
      {#each entries as [key, value]}<div><dt>{humanFieldLabel(key)}</dt><dd>{display(value)}</dd></div>{/each}
    </dl>
  {/if}
  {#if runtime.state === "loading"}<p role="status">확인된 내용을 불러오는 중입니다.</p>
  {:else if runtime.state === "error"}<p role="alert">이 영역을 확인하지 못했습니다. 잠시 후 다시 시도하세요.</p>
  {:else if runtime.state === "forbidden" || runtime.state === "unauthorized"}<p role="alert">현재 권한으로는 이 영역을 열 수 없습니다.</p>
  {:else if runtime.state === "empty" || (declaredFields.length > 0 && entries.length === 0)}<p role="status">이 범위에 확인 가능한 기록이 없습니다.</p>
  {:else if runtime.state === "stale" || runtime.state === "partial"}<p class="inline-state stale" role="status">일부 정보가 오래되었거나 누락되었습니다. 최신 상태를 확인하세요.</p>{/if}
</section>
