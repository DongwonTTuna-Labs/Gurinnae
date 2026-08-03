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
  class="operations-layout"
  data-archetype-assembly="operations"
  data-authority-archetype={screen.archetype}
  data-component="OperationsAssembly"
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
  .operations-layout {
    min-width: 0;
    display: grid;
    grid-template-columns: repeat(12, minmax(0, 1fr));
    column-gap: 0.875rem;
    align-items: start;
  }

  .operations-layout > :global(.section-grid) {
    display: contents;
  }

  .operations-layout :global(.section) {
    grid-column: span 4;
  }

  .operations-layout :global(.section:first-child) {
    grid-column: 1 / -1;
  }

  .operations-layout
    :global(.section:is(
      [data-component="DataCollection"],
      [data-component="OperationsStatusPanel"]
    )) {
    grid-column: span 6;
  }

  .operations-layout > :global(#page-actions) {
    grid-column: 1 / -1;
  }

  @media (max-width: 900px) {
    .operations-layout {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }

    .operations-layout :global(.section.section) {
      grid-column: auto;
    }

    .operations-layout
      :global(.section:is(
        :first-child,
        [data-component="DataCollection"],
        [data-component="OperationsStatusPanel"]
      )) {
      grid-column: 1 / -1;
    }
  }

  @media (max-width: 620px) {
    .operations-layout {
      grid-template-columns: minmax(0, 1fr);
    }

    .operations-layout :global(.section.section) {
      grid-column: 1 / -1;
    }
  }
</style>
