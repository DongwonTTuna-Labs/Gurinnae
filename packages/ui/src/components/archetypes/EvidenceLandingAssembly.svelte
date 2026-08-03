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
  class="evidence-landing-layout"
  data-screen={screen.id}
  data-archetype-assembly="evidence-landing"
  data-authority-archetype={screen.archetype}
  data-component="EvidenceLandingAssembly"
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
  .evidence-landing-layout {
    min-width: 0;
    display: grid;
    grid-template-columns: repeat(12, minmax(0, 1fr));
    column-gap: 0.875rem;
    align-items: start;
  }

  .evidence-landing-layout > :global(.section-grid) {
    display: contents;
  }

  .evidence-landing-layout :global(.section) {
    grid-column: span 4;
  }

  .evidence-landing-layout
    :global(.section:is(
      [data-component="ComparisonWorkbench"],
      [data-component="DecisionReviewPanel"],
      [data-component="EvidenceLedger"],
      [data-component="LongFormArticle"]
    )) {
    grid-column: span 6;
  }

  .evidence-landing-layout
    :global(.section:is(
      [data-component="SignalTriagePanel"],
      [data-component="UnifiedSearch"]
    )),
  .evidence-landing-layout > :global(#page-actions) {
    grid-column: 1 / -1;
  }

  @media (min-width: 1101px) {
    .evidence-landing-layout[data-screen="PUB-004"]
      :global(.section:is(#timeline, #revision)) {
      grid-column: span 3;
    }

    .evidence-landing-layout[data-screen="PUB-004"]
      > :global(#page-actions .action-grid) {
      grid-template-columns: auto auto minmax(0, 1fr);
    }

    .evidence-landing-layout[data-screen="PUB-004"]
      > :global(#page-actions .action-grid form) {
      grid-column: auto;
      grid-template-columns: repeat(7, minmax(0, 1fr));
    }

    .evidence-landing-layout[data-screen="PUB-004"]
      > :global(#page-actions .action-grid form > h3) {
      grid-column: 1;
      grid-row: 1;
    }

    .evidence-landing-layout[data-screen="PUB-004"]
      > :global(#page-actions .action-grid form > p) {
      grid-column: 2 / 5;
      grid-row: 1;
    }

    .evidence-landing-layout[data-screen="PUB-004"]
      > :global(#page-actions .action-grid form > .bot-challenge) {
      grid-column: 5 / 7;
      grid-row: 1;
    }

    .evidence-landing-layout[data-screen="PUB-004"]
      > :global(#page-actions .action-grid form > button) {
      grid-column: 7;
      grid-row: 1;
    }

    .evidence-landing-layout[data-screen="PUB-012"]
      > :global(#page-actions .section-content) {
      grid-template-columns: auto auto minmax(0, 1fr);
      align-items: center;
    }

    .evidence-landing-layout[data-screen="PUB-012"]
      > :global(#page-actions .action-grid) {
      grid-column: auto;
      grid-template-columns: repeat(3, max-content);
    }

    .evidence-landing-layout[data-screen="PUB-012"]
      > :global(#page-actions .local-action) {
      margin-top: 0;
    }

    .evidence-landing-layout[data-screen="PUB-012"]
      > :global(#page-actions .row-selection-navigation) {
      padding-block: 0;
    }
  }

  @media (max-width: 900px) {
    .evidence-landing-layout {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }

    .evidence-landing-layout :global(.section.section) {
      grid-column: auto;
    }

    .evidence-landing-layout
      :global(.section:is(
        [data-component="ComparisonWorkbench"],
        [data-component="DecisionReviewPanel"],
        [data-component="EvidenceLedger"],
        [data-component="LongFormArticle"],
        [data-component="SignalTriagePanel"],
        [data-component="UnifiedSearch"]
      )) {
      grid-column: 1 / -1;
    }
  }

  @media (max-width: 620px) {
    .evidence-landing-layout {
      grid-template-columns: minmax(0, 1fr);
    }

    .evidence-landing-layout :global(.section.section) {
      grid-column: 1 / -1;
    }
  }
</style>
