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
  class="record-layout"
  data-archetype-assembly="record"
  data-authority-archetype={screen.archetype}
  data-component="RecordAssembly"
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
  .record-layout {
    min-width: 0;
    display: grid;
    grid-template-columns: repeat(12, minmax(0, 1fr));
    column-gap: 0.875rem;
    align-items: start;
  }

  .record-layout > :global(.section-grid) {
    display: contents;
  }

  .record-layout[data-authority-archetype="SEARCH_INDEX"]
    :global(.section:first-child),
  .record-layout[data-authority-archetype="SEARCH_INDEX"]
    :global(.section:nth-child(n + 4)),
  .record-layout > :global(#page-actions) {
    grid-column: 1 / -1;
  }

  .record-layout[data-authority-archetype="SEARCH_INDEX"]
    :global(.section:nth-child(2)) {
    grid-column: span 3;
  }

  .record-layout[data-authority-archetype="SEARCH_INDEX"]
    :global(.section:nth-child(3)) {
    grid-column: span 9;
  }

  .record-layout[data-authority-archetype="ENTITY_DETAIL"]
    :global(.section) {
    grid-column: span 4;
  }

  .record-layout[data-authority-archetype="ENTITY_DETAIL"]
    :global(.section:nth-child(-n + 2)) {
    grid-column: span 6;
  }

  .record-layout[data-authority-archetype="ENTITY_DETAIL"]
    :global(.section:is(
      [data-component="DataCollection"],
      [data-component="GuidedFormSection"],
      [data-component="LongFormArticle"],
      [data-component="SignalTriagePanel"]
    )) {
    grid-column: span 8;
  }

  @media (max-width: 900px) {
    .record-layout {
      grid-template-columns: minmax(0, 1fr);
    }

    .record-layout[data-authority-archetype]
      :global(.section.section) {
      grid-column: 1 / -1;
    }
  }
</style>
