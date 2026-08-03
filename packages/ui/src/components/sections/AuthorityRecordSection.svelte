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
    <p class="inline-state conflict" role="status">서버 권위 투영값이 없어 이 영역을 표시할 수 없습니다.</p>
  {/if}
  {#if projection?.state === "LOADING" || runtime.state === "loading"}<p role="status">확인된 내용을 불러오는 중입니다.</p>
  {:else if runtime.state === "error"}<p role="status">이 영역을 확인하지 못했습니다. 잠시 후 다시 시도하세요.</p>
  {:else if runtime.state === "forbidden" || runtime.state === "unauthorized"}<p role="status">현재 권한으로는 이 영역을 열 수 없습니다.</p>
  {:else if runtime.state === "empty" || declaredFields.length === 0}<p role="status">이 범위에 확인 가능한 기록이 없습니다.</p>
  {:else if runtime.state === "stale" || runtime.state === "partial"}<p class="inline-state stale" role="status">일부 정보가 오래되었거나 누락되었습니다. 최신 상태를 확인하세요.</p>{/if}
</section>

<style>
  .authority-record-section {
    display: grid;
    gap: 0.375rem;
    min-width: 0;
  }

  .semantic-facts {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 19rem), 1fr));
    column-gap: 1px;
    margin: 0;
    padding: 0;
    border: 0;
    border-top: 1px solid var(--paper-200);
    border-radius: 0;
    background: var(--paper-200);
  }

  .semantic-facts > div {
    display: grid;
    grid-template-columns: minmax(6.5rem, 38%) minmax(0, 1fr);
    gap: 0.625rem;
    align-items: baseline;
    min-width: 0;
    padding: 0.375rem 0.5rem;
    border-top: 0;
    border-bottom: 1px solid var(--paper-200);
    background: var(--paper-0);
  }

  .semantic-facts dt {
    color: var(--ink-500);
    font-size: 0.75rem;
    font-weight: 650;
  }

  .semantic-facts dd {
    min-width: 0;
    margin: 0;
    color: var(--ink-950);
    font-size: 0.875rem;
    line-height: 1.4;
    overflow-wrap: anywhere;
  }

  .authority-record-section > p {
    display: flex;
    gap: 0.5rem;
    align-items: flex-start;
    margin: 0;
    padding: 0.375rem 0.5rem;
    border-block: 1px solid var(--paper-200);
    background: var(--paper-50);
    color: var(--ink-700);
    font-size: 0.875rem;
    line-height: 1.4;
  }

  .authority-record-section > p::before {
    width: 0.45rem;
    height: 0.45rem;
    flex: 0 0 auto;
    margin-top: 0.4em;
    border-radius: 50%;
    background: var(--blue-500);
    content: "";
  }

  .authority-record-section > p.conflict {
    border-color: var(--red-500);
    background: var(--red-50);
    color: var(--red-900);
  }

  .authority-record-section > p.conflict::before {
    background: var(--red-500);
  }

  [data-projection-state="UNKNOWN"] > p.conflict,
  [data-projection-state="STALE"] > p.conflict {
    border-color: var(--amber-500);
    background: var(--amber-50);
    color: var(--amber-900);
  }

  [data-projection-state="UNKNOWN"] > p.conflict::before,
  [data-projection-state="STALE"] > p.conflict::before {
    background: var(--amber-500);
  }

  .authority-record-section > p.stale {
    border-color: var(--amber-500);
    background: var(--amber-50);
    color: var(--amber-900);
  }

  .authority-record-section > p.stale::before {
    background: var(--amber-500);
  }

  @media (max-width: 620px) {
    .semantic-facts {
      grid-template-columns: 1fr;
      column-gap: 0;
    }
  }

  @media (forced-colors: active) {
    .semantic-facts,
    .semantic-facts > div,
    .authority-record-section > p {
      border-color: CanvasText;
      background: Canvas;
      color: CanvasText;
    }
  }
</style>
