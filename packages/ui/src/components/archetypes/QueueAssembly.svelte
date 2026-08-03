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
  class="queue-layout"
  data-screen={screen.id}
  data-archetype-assembly="queue"
  data-authority-archetype={screen.archetype}
  data-component="QueueAssembly"
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
  .queue-layout {
    min-width: 0;
    display: grid;
    grid-template-columns: repeat(12, minmax(0, 1fr));
    column-gap: 0.875rem;
    align-items: start;
  }

  .queue-layout > :global(.section-grid) {
    display: contents;
  }

  .queue-layout :global(.section) {
    grid-column: span 4;
  }

  .queue-layout
    :global(.section:is(
      [data-component="DataCollection"],
      [data-component="OperationsStatusPanel"],
      [id="jobs"],
      [id="notifications"],
      [id="queue"],
      [id="requests"],
      [id="runs"],
      [id="table"],
      [id="tasks"]
    )) {
    grid-column: span 8;
  }

  .queue-layout > :global(#page-actions) {
    grid-column: 1 / -1;
  }

  @media (min-width: 1101px) {
    .queue-layout[data-screen="INT-002"]
      :global(.section:is(#views, #tasks, #filters)) {
      grid-column: span 4;
    }

    .queue-layout[data-screen="INT-002"]
      :global(.section#handoff) {
      grid-column: 1 / -1;
    }

    .queue-layout[data-screen="INT-002"]
      :global(.section#handoff > .section-content) {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 0.75rem;
      align-items: start;
    }

    .queue-layout[data-screen="INT-002"]
      :global(.section#handoff > .section-content > .section-heading) {
      grid-column: 1 / -1;
    }

    .queue-layout[data-screen="INT-002"]
      :global(.section#handoff > .section-content > .structured-content) {
      grid-column: 1;
      grid-row: 2;
    }

    .queue-layout[data-screen="INT-002"]
      :global(.section#handoff > .section-content > .omnichannel-approval) {
      grid-column: 2;
      grid-row: 2 / span 2;
    }

    .queue-layout[data-screen="INT-002"]
      :global(.section#handoff > .section-content > .execution-receipt) {
      grid-column: 1;
      grid-row: 3;
    }

    .queue-layout[data-screen="INT-002"]
      :global(.section#handoff .selected-approval-target),
    .queue-layout[data-screen="INT-002"]
      :global(.section#handoff .approval-queue-card),
    .queue-layout[data-screen="INT-002"]
      :global(.section#handoff .approval-queue-card > div) {
      grid-template-columns: minmax(0, 1fr);
    }

    .queue-layout[data-screen="INT-002"]
      > :global(#page-actions .action-grid) {
      grid-template-columns: repeat(5, minmax(0, 1fr));
    }

    .queue-layout[data-screen="INT-002"]
      > :global(#page-actions .action-grid form) {
      grid-column: auto;
      grid-template-columns: minmax(0, 1fr);
    }

    .queue-layout[data-screen="INT-002"]
      > :global(#page-actions .action-grid form label) {
      grid-template-columns: minmax(4.5rem, 0.8fr) minmax(0, 1fr);
      gap: 0.5rem;
      align-items: center;
    }
  }

  @media (max-width: 900px) {
    .queue-layout {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }

    .queue-layout :global(.section.section) {
      grid-column: auto;
    }

    .queue-layout
      :global(.section:is(
        [data-component="DataCollection"],
        [data-component="OperationsStatusPanel"],
        [id="jobs"],
        [id="notifications"],
        [id="queue"],
        [id="requests"],
        [id="runs"],
        [id="table"],
        [id="tasks"]
      )) {
      grid-column: 1 / -1;
    }
  }

  @media (max-width: 620px) {
    .queue-layout {
      grid-template-columns: minmax(0, 1fr);
    }

    .queue-layout :global(.section.section) {
      grid-column: 1 / -1;
    }
  }
</style>
