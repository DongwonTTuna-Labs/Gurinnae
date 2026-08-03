<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import { typedScreenViewModel } from "../../screen-contract";
import { authoritySectionStatus } from "../../screen-projection-values";
import ProjectionValue from "../ProjectionValue.svelte";
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
const status = $derived(
  authoritySectionStatus({
    projectionPresent: projection !== undefined,
    ...(projection ? { projectionState: projection.state } : {}),
    runtimeState: runtime.state,
    ...(projection?.errorMessage
      ? { errorMessage: projection.errorMessage }
      : {}),
    declaredFieldCount: declaredFields.length,
    knownFieldCount: knownFields.length,
  }),
);
</script>

<SectionHeading {section} {kicker} />
<section class="authority-record-section" data-testid={section.test_id} data-region={projection?.region ?? typedSection?.region ?? "state"} data-projection-state={projection?.state} aria-busy={runtime.state === "loading"}>
  {#if status}
    <p class:inline-state={status.tone === "neutral"} class:conflict={status.tone === "conflict"} class:stale={status.tone === "stale"} role={status.tone === "conflict" ? "alert" : "status"}>{status.message}</p>
  {/if}
  {#if knownFields.length > 0 && !status?.suppressValues}
    <dl class="semantic-facts" aria-label={`${section.title} 계약 필드`}>
      {#each knownFields as field}<div><dt>{field.label}</dt><dd><ProjectionValue name={field.name} label={field.label} value={field.value} /></dd></div>{/each}
    </dl>
  {/if}
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
