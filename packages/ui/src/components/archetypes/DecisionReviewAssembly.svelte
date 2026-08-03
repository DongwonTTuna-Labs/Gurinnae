<script lang="ts">
import SectionList from "../screen/SectionList.svelte";
import type { ArchetypeAssemblyProps } from "./archetype-assembly";

let {
  screen,
  runtime,
  contract,
  projection,
  skipStatus = false,
  variant = "standard",
}: ArchetypeAssemblyProps = $props();
</script>

<div
  class="decision-review-layout"
  data-screen={screen.id}
  data-archetype-assembly="decision-review"
  data-authority-archetype={screen.archetype}
  data-component="DecisionReviewAssembly"
>
  <SectionList
    {screen}
    {runtime}
    {contract}
    {projection}
    {skipStatus}
    {variant}
  />
</div>

<style>
  .decision-review-layout {
    min-width: 0;
    display: grid;
    grid-template-columns: repeat(12, minmax(0, 1fr));
    column-gap: 0.875rem;
    align-items: start;
  }

  .decision-review-layout > :global(.section-grid) {
    display: contents;
  }

  .decision-review-layout :global(.section) {
    grid-column: span 4;
  }

  .decision-review-layout :global(.section:first-child),
  .decision-review-layout
    :global(.section:is(
      [data-component="ComparisonWorkbench"],
      [data-component="DataCollection"],
      [data-component="EvidenceLedger"]
    )) {
    grid-column: span 8;
  }

  .decision-review-layout
    :global(.section[data-component="SignalTriagePanel"]),
  .decision-review-layout > :global(#page-actions) {
    grid-column: 1 / -1;
  }

  @media (min-width: 1101px) {
    .decision-review-layout[data-screen="SRC-006"]
      :global(.section:is(#dedupe, #downstream, #safety)),
    .decision-review-layout[data-screen="RULE-004"]
      :global(.section:is(#target, #gates, #schedule, #rollback, #approval)) {
      grid-column: span 8;
    }

    .decision-review-layout[data-screen="SIG-002"] {
      grid-template-columns: repeat(4, minmax(0, 1fr));
    }

    .decision-review-layout[data-screen="SIG-002"]
      :global(.section.section) {
      grid-column: span 1;
    }

    .decision-review-layout[data-screen="SIG-002"]
      :global(.section:is(#calculation, #cohort, #provenance, #related)) {
      grid-column: span 2;
    }

    .decision-review-layout[data-screen="SIG-002"]
      > :global(#page-actions) {
      grid-column: 1 / -1;
    }

    .decision-review-layout:is(
        [data-screen="SIG-002"],
        [data-screen="SRC-006"],
        [data-screen="RULE-004"]
      )
      > :global(#page-actions .action-grid) {
      grid-template-columns: repeat(3, minmax(0, 1fr));
    }

    .decision-review-layout[data-screen="SIG-002"]
      > :global(#page-actions .action-grid) {
      grid-template-columns: repeat(5, minmax(0, 1fr));
    }

    .decision-review-layout[data-screen="SIG-002"]
      > :global(#page-actions .action-grid form) {
      padding-block: 0;
      row-gap: 0.125rem;
    }

    .decision-review-layout:is(
        [data-screen="SIG-002"],
        [data-screen="SRC-006"],
        [data-screen="RULE-004"]
      )
      > :global(#page-actions .action-grid form) {
      grid-column: auto;
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }
  }

  @media (max-width: 900px) {
    .decision-review-layout {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }

    .decision-review-layout :global(.section.section) {
      grid-column: auto;
    }

    .decision-review-layout
      :global(.section:is(
        :first-child,
        [data-component="ComparisonWorkbench"],
        [data-component="DataCollection"],
        [data-component="EvidenceLedger"],
        [data-component="SignalTriagePanel"]
      )) {
      grid-column: 1 / -1;
    }
  }

  @media (max-width: 620px) {
    .decision-review-layout {
      grid-template-columns: minmax(0, 1fr);
    }

    .decision-review-layout :global(.section.section) {
      grid-column: 1 / -1;
    }
  }
</style>
