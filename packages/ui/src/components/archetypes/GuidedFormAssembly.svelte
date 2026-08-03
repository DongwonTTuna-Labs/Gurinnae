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
  class="guided-form-layout"
  data-screen={screen.id}
  data-archetype-assembly="guided-form"
  data-authority-archetype={screen.archetype}
  data-component="GuidedFormAssembly"
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
  .guided-form-layout {
    min-width: 0;
    display: grid;
    grid-template-columns: repeat(12, minmax(0, 1fr));
    column-gap: 0.875rem;
    align-items: start;
  }

  .guided-form-layout > :global(.section-grid) {
    display: contents;
  }

  .guided-form-layout[data-authority-archetype="GUIDED_FORM"]
    :global(.section) {
    grid-column: span 4;
  }

  .guided-form-layout[data-authority-archetype="GUIDED_FORM"]
    :global(.section:is(
      [data-component="DataCollection"],
      [data-component="EvidenceLedger"],
      [data-component="GuidedFormSection"],
      [data-component="KnownUnknownResponse"]
    )) {
    grid-column: span 8;
  }

  .guided-form-layout[data-authority-archetype="AUTH_SYSTEM"] {
    width: 100%;
    max-width: 42rem;
    margin-inline: auto;
    grid-template-columns: minmax(0, 1fr);
  }

  .guided-form-layout[data-authority-archetype="AUTH_SYSTEM"]
    :global(.section),
  .guided-form-layout > :global(#page-actions) {
    grid-column: 1 / -1;
  }

  @media (min-width: 1101px) {
    .guided-form-layout[data-screen="CAS-009"]
      :global(.section:is(#preview, #gate)) {
      grid-column: 1 / -1;
    }

    .guided-form-layout[data-screen="CAS-009"]
      > :global(#page-actions .action-grid) {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }

    .guided-form-layout[data-screen="CAS-009"]
      > :global(#page-actions .action-grid form) {
      grid-column: auto;
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }
  }

  @media (max-width: 900px) {
    .guided-form-layout[data-authority-archetype="GUIDED_FORM"] {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }

    .guided-form-layout[data-authority-archetype="GUIDED_FORM"]
      :global(.section.section) {
      grid-column: auto;
    }

    .guided-form-layout[data-authority-archetype="GUIDED_FORM"]
      :global(.section:is(
        [data-component="DataCollection"],
        [data-component="EvidenceLedger"],
        [data-component="GuidedFormSection"],
        [data-component="KnownUnknownResponse"]
      )) {
      grid-column: 1 / -1;
    }
  }

  @media (max-width: 620px) {
    .guided-form-layout[data-authority-archetype="GUIDED_FORM"] {
      grid-template-columns: minmax(0, 1fr);
    }

    .guided-form-layout[data-authority-archetype="GUIDED_FORM"]
      :global(.section.section) {
      grid-column: 1 / -1;
    }
  }
</style>
