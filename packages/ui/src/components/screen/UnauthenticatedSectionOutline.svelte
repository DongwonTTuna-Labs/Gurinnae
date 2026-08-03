<script lang="ts">
import type { ScreenViewModel, TypedScreenViewModel } from "../../index";
import { sourceSectionForId } from "../../screen-chrome";
import type { ScreenProjection } from "../../screen-projection";
import SectionHeading from "../sections/SectionHeading.svelte";

let {
  screen,
  contract,
  projection,
}: {
  screen: ScreenViewModel;
  contract: TypedScreenViewModel;
  projection: ScreenProjection;
} = $props();
</script>

<div class="access-outline" data-component="UnauthenticatedSectionOutline">
  {#each contract.sections as typedSection (typedSection.id)}
    {@const section = sourceSectionForId(screen, typedSection.id)}
    <section
      id={typedSection.id}
      tabindex="-1"
      aria-labelledby={`section-${typedSection.id}-heading`}
      data-testid={typedSection.testId}
      data-focus-target={projection.sections[typedSection.id]?.focusTarget}
      data-component={typedSection.component}
      data-projection-state="BLOCKED"
      class="section"
    >
      <SectionHeading {section} kicker="확인 항목" />
    </section>
  {/each}
</div>

<style>
  .access-outline {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    column-gap: 0.875rem;
    border-block: 1px solid var(--paper-200);
  }

  .section {
    min-width: 0;
    padding: 0.625rem 0;
    border-top: 1px solid var(--paper-200);
    scroll-margin-top: 7.5rem;
  }

  .section:nth-child(-n + 2) {
    border-top: 0;
  }

  @media (max-width: 620px) {
    .access-outline {
      grid-template-columns: minmax(0, 1fr);
    }

    .section:nth-child(2) {
      border-top: 1px solid var(--paper-200);
    }
  }
</style>
