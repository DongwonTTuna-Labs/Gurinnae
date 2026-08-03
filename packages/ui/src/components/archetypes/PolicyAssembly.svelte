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
  class="policy-layout"
  data-archetype-assembly="policy"
  data-authority-archetype={screen.archetype}
  data-component="PolicyAssembly"
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
  .policy-layout {
    min-width: 0;
    display: grid;
    grid-template-columns: repeat(12, minmax(0, 1fr));
    column-gap: 0.875rem;
    align-items: start;
  }

  .policy-layout > :global(.section-grid) {
    display: contents;
  }

  .policy-layout :global(.section) {
    grid-column: span 4;
  }

  .policy-layout :global(.section:first-child),
  .policy-layout :global(.section[data-component="LongFormArticle"]) {
    grid-column: span 8;
  }

  .policy-layout
    :global(.section:is(
      [data-component="LongFormArticle"],
      [data-component="StructuredContentSection"]
    ) .section-content) {
    max-width: 72ch;
  }

  .policy-layout > :global(#page-actions) {
    grid-column: 1 / -1;
  }

  @media (max-width: 900px) {
    .policy-layout {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }

    .policy-layout :global(.section.section) {
      grid-column: auto;
    }

    .policy-layout :global(.section:first-child),
    .policy-layout :global(.section[data-component="LongFormArticle"]) {
      grid-column: 1 / -1;
    }
  }

  @media (max-width: 620px) {
    .policy-layout {
      grid-template-columns: minmax(0, 1fr);
    }

    .policy-layout :global(.section.section) {
      grid-column: 1 / -1;
    }
  }
</style>
