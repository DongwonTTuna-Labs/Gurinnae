<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import { humanFieldLabel, typedScreenViewModel } from "../../screen-contract";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let {
  section,
  screen,
  runtime,
  projection,
  embedded = false,
}: ScreenSectionProps & { embedded?: boolean } = $props();
const contract = $derived(typedScreenViewModel(screen));
const links = $derived(
  projection?.fields.filter(
    (field) => field.name.endsWith("_href") && field.known,
  ) ?? [],
);
const showJourneyLead = $derived(contract.sections[0]?.id === section.id);
</script>

{#if !embedded}<SectionHeading {section} kicker="제출·영수증 확인" />{/if}
<div class="journey-section" data-journey={contract.journey} data-region={contract.sections.find((item) => item.id === section.id)?.region ?? "state"} aria-busy={runtime.state === "loading"}>
  {#if showJourneyLead}<p class="journey-lead">서버가 확인한 제출 결과와 영수증만 표시합니다. 수정은 새 영수증으로 남습니다.</p>{/if}
  {#if projection}
    <OperationData {runtime} {projection} mode="cards" emptyLabel="확인 가능한 제출 정보가 없습니다." />
    {#if links.length > 0}
      <nav class="receipt-links" aria-label="영수증 관련 작업">
        {#each links as link}<a class="secondary-button" href={String(link.value)}>{humanFieldLabel(link.name)}</a>{/each}
      </nav>
    {/if}
  {:else}<p role="status">제출 투영값을 불러오는 중입니다.</p>{/if}
  {#if runtime.state === "conflict"}<p class="inline-state conflict" role="status">영수증 버전이 변경되었습니다. 최신 영수증을 다시 확인하세요.</p>
  {:else if runtime.state === "stale" || runtime.state === "superseded"}<p class="inline-state stale" role="status">영수증 정보가 오래되었습니다. 새로고침 후 확인하세요.</p>
  {:else if runtime.state === "forbidden" || runtime.state === "unauthenticated"}<p class="inline-state forbidden" role="status">현재 세션에서는 이 영수증을 확인할 수 없습니다.</p>{/if}
</div>

<style>
  .journey-section {
    display: grid;
    gap: 0.75rem;
    min-width: 0;
  }

  .journey-lead,
  .journey-section > p[role="status"] {
    margin: 0;
    color: var(--ink-700);
    font-size: var(--text-help, 0.8125rem);
    line-height: 1.5;
  }

  .journey-lead {
    padding: 0.5rem 0.625rem;
    border-left: 2px solid var(--blue-500);
    background: var(--blue-50);
  }

  .receipt-links {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem;
    padding-top: 0.625rem;
    border-top: 1px solid var(--paper-200);
  }

  .receipt-links a {
    min-height: var(--target-min);
    font-size: var(--text-help, 0.8125rem);
  }

  .inline-state {
    margin: 0;
    padding: 0.5rem 0.625rem;
    border-left: 2px solid var(--blue-500);
    color: var(--ink-700);
    font-size: var(--text-help, 0.8125rem);
    line-height: 1.5;
  }

  .inline-state.conflict,
  .inline-state.forbidden {
    border-color: var(--red-500);
    background: var(--red-50);
    color: var(--red-900);
  }

  .inline-state.stale {
    border-color: var(--amber-500);
    background: var(--amber-50);
    color: var(--amber-900);
  }

  @media (max-width: 620px) {
    .journey-section {
      gap: 0.625rem;
    }

    .receipt-links {
      display: grid;
      grid-template-columns: minmax(0, 1fr);
    }

    .receipt-links a {
      width: 100%;
    }
  }
</style>
