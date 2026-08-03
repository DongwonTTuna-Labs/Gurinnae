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
  class="workspace-layout"
  data-screen={screen.id}
  data-archetype-assembly="workspace"
  data-authority-archetype={screen.archetype}
  data-component="WorkspaceAssembly"
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
  .workspace-layout {
    min-width: 0;
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    column-gap: 0.875rem;
    align-items: start;
  }

  .workspace-layout > :global(.section-grid) {
    display: contents;
  }

  .workspace-layout :global(.section) {
    grid-column: span 1;
  }

  .workspace-layout
    :global(.section:is(
      [data-component="ClaimWorkbench"],
      [data-component="DataCollection"],
      [data-component="DecisionReviewPanel"],
      [data-component="EvidenceLedger"],
      [data-component="KnownUnknownResponse"],
      [data-component="UnifiedSearch"]
    )) {
    grid-column: span 2;
  }

  .workspace-layout
    :global(.section:is(
      [data-component="GuidedFormSection"],
      [data-component="LongFormArticle"]
    )),
  .workspace-layout > :global(#page-actions) {
    grid-column: 1 / -1;
  }

  @media (min-width: 1101px) {
    .workspace-layout[data-screen="CAS-010"] :global(.section#runs) {
      grid-column: 1 / -1;
    }

    .workspace-layout[data-screen="CAS-010"] :global(.section#budget) {
      grid-column: 1 / -1;
    }

    .workspace-layout[data-screen="CAS-011"] {
      grid-template-columns: repeat(4, minmax(0, 1fr));
    }

    .workspace-layout[data-screen="CAS-011"]
      :global(.section:is(#identity, #inputs, #citations, #safety, #decisions, #cost)) {
      grid-column: span 2;
    }

    .workspace-layout[data-screen="CAS-011"] :global(.section#model) {
      grid-column: span 1;
    }

    .workspace-layout[data-screen="CAS-011"] :global(.section#output) {
      grid-column: span 3;
    }

    .workspace-layout[data-screen="CAS-011"] :global(.section#decisions) {
      grid-column: span 3;
    }

    .workspace-layout[data-screen="CAS-011"] :global(.section#cost) {
      grid-column: span 1;
    }

    .workspace-layout[data-screen="CAS-011"] > :global(#page-actions) {
      grid-column: 1 / -1;
    }

    .workspace-layout[data-screen="CAS-011"]
      :global(.section .data-card dl) {
      grid-template-columns: repeat(3, minmax(0, 1fr));
    }

    .workspace-layout[data-screen="CAS-011"]
      :global(.section .data-card dl > div) {
      grid-template-columns: minmax(0, 1fr);
      gap: 0.125rem;
    }

    .workspace-layout[data-screen="CAS-011"] :global(.section.section) {
      padding-block: 0.25rem;
    }

    .workspace-layout[data-screen="CAS-011"]
      :global(.section .section-heading) {
      margin-bottom: 0;
    }

    .workspace-layout[data-screen="CAS-011"]
      :global(.section .analysis-projection-note) {
      padding-block: 0.125rem;
    }

    .workspace-layout[data-screen="CAS-005"]
      :global(.section:is(#content, #access)),
    .workspace-layout[data-screen="CAS-006"]
      :global(.section:is(#editor, #lint, #relationships)) {
      grid-column: span 2;
    }

    .workspace-layout[data-screen="CAS-011"]
      :global(.section:is(#inputs, #output) > .section-content) {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 0.75rem;
      align-items: start;
    }

    .workspace-layout[data-screen="CAS-011"]
      :global(.section:is(#inputs, #output) > .section-content > .section-heading),
    .workspace-layout[data-screen="CAS-011"]
      :global(.section:is(#inputs, #output) > .section-content > .analysis-projection-note) {
      grid-column: 1 / -1;
    }

    .workspace-layout[data-screen="CAS-011"]
      :global(.section:is(#inputs, #output) > .section-content > .projection-data) {
      grid-column: span 2;
    }

    .workspace-layout[data-screen="CAS-011"]
      :global(.section:is(#inputs, #output) > .section-content > :is(.analysis-provenance, .analysis-visualizations)) {
      margin-top: 0;
    }

    .workspace-layout[data-screen="CAS-011"]
      :global(.section#decisions > .section-content) {
      display: grid;
      grid-template-columns: minmax(0, 2fr) minmax(0, 1fr);
      gap: 0 0.75rem;
      align-items: start;
    }

    .workspace-layout[data-screen="CAS-011"]
      :global(.section#decisions > .section-content > :is(.section-heading, .projection-data)) {
      grid-column: 1 / -1;
    }

    .workspace-layout[data-screen="CAS-011"] > :global(#page-actions) {
      padding-block: 0;
    }

    .workspace-layout[data-screen="CAS-010"]
      > :global(#page-actions .action-grid form),
    .workspace-layout[data-screen="CAS-011"]
      > :global(#page-actions .action-grid form) {
      grid-template-columns: repeat(3, minmax(0, 1fr));
    }

    .workspace-layout[data-screen="CAS-011"]
      > :global(#page-actions .action-grid form) {
      grid-template-columns: repeat(6, minmax(0, 1fr));
    }

    .workspace-layout[data-screen="CAS-011"]
      > :global(#page-actions .action-grid form > h3) {
      grid-column: 1;
      grid-row: 1;
    }

    .workspace-layout[data-screen="CAS-011"]
      > :global(#page-actions .action-grid form > p) {
      grid-column: 2 / 6;
      grid-row: 1;
    }

    .workspace-layout[data-screen="CAS-011"]
      > :global(#page-actions .action-grid form > button) {
      grid-column: 6;
      grid-row: 1;
    }

    .workspace-layout[data-screen="CAS-011"]
      > :global(#page-actions .action-grid form > label) {
      grid-row: 2;
    }

    .workspace-layout[data-screen="CAS-005"]
      > :global(#page-actions .action-grid),
    .workspace-layout[data-screen="CAS-006"]
      > :global(#page-actions .action-grid),
    .workspace-layout[data-screen="COR-002"]
      > :global(#page-actions .action-grid) {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }

    .workspace-layout[data-screen="CAS-005"]
      > :global(#page-actions .action-grid form),
    .workspace-layout[data-screen="CAS-006"]
      > :global(#page-actions .action-grid form),
    .workspace-layout[data-screen="COR-002"]
      > :global(#page-actions .action-grid form) {
      grid-column: auto;
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }
  }

  @media (max-width: 900px) {
    .workspace-layout {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }

    .workspace-layout :global(.section.section) {
      grid-column: auto;
    }

    .workspace-layout
      :global(.section:is(
        [data-component="ClaimWorkbench"],
        [data-component="DataCollection"],
        [data-component="DecisionReviewPanel"],
        [data-component="EvidenceLedger"],
        [data-component="GuidedFormSection"],
        [data-component="KnownUnknownResponse"],
        [data-component="LongFormArticle"],
        [data-component="UnifiedSearch"]
      )) {
      grid-column: 1 / -1;
    }
  }

  @media (max-width: 620px) {
    .workspace-layout {
      grid-template-columns: minmax(0, 1fr);
    }

    .workspace-layout :global(.section.section) {
      grid-column: 1 / -1;
    }
  }
</style>
