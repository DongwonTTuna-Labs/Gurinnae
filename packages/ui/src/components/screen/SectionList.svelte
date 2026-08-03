<script lang="ts">
import type {
  ScreenRuntime,
  ScreenViewModel,
  TypedScreenViewModel,
} from "../../index";
import {
  publicActionPlacement,
  sectionActionIds,
} from "../../public-action-placement";
import {
  sourceSectionForId,
  statusSectionIdForScreen,
} from "../../screen-chrome";
import type { ScreenProjection } from "../../screen-projection";
import ScreenActions from "../ScreenActions.svelte";
import ScreenSection from "../ScreenSection.svelte";

let {
  screen,
  runtime,
  contract,
  projection,
  skipStatus = false,
  variant = "standard",
}: {
  screen: ScreenViewModel;
  runtime: ScreenRuntime;
  contract: TypedScreenViewModel;
  projection: ScreenProjection;
  skipStatus?: boolean;
  variant?: "standard" | "workspace" | "form";
} = $props();
const statusSectionId = $derived(statusSectionIdForScreen(screen.sections));
const actionPlacement = $derived(publicActionPlacement(screen));
</script>

<div class="section-grid" class:form-grid={variant === "form" || screen.archetype === "GUIDED_FORM"} class:workspace-grid={variant === "workspace"} class:donation-grid={screen.id === "PUB-035"}>
  {#each contract.sections as typedSection, index (typedSection.id)}
    {@const section = sourceSectionForId(screen, typedSection.id)}
    {@const inlineActionIds = sectionActionIds(actionPlacement, typedSection.id)}
    {@const ownsAttachments = actionPlacement?.attachmentSectionId === typedSection.id}
    {#if !(skipStatus && typedSection.id === statusSectionId)}
      <section id={typedSection.id} tabindex="-1" aria-labelledby={`section-${typedSection.id}-heading`} data-testid={typedSection.testId} data-focus-target={projection.sections[typedSection.id]?.focusTarget} data-component={typedSection.component} data-projection-state={projection.sections[typedSection.id]?.state} class="section" class:form-section={variant === "form"} class:primary={typedSection.region === "priority"} class:workspace-section={variant === "workspace"}>
        <div class="section-content">
          <ScreenSection {section} {screen} {runtime} {index} projection={projection.sections[typedSection.id]} />
          {#if actionPlacement}<ScreenActions {screen} {runtime} actionIds={inlineActionIds} attachments={ownsAttachments} context="section" />{/if}
        </div>
      </section>
    {/if}
  {/each}
</div>
{#if !actionPlacement}<ScreenActions {screen} {runtime} />{/if}

<style>
  .section-grid {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    column-gap: 0.875rem;
    align-items: start;
  }

  .form-grid,
  .workspace-grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }

  .donation-grid {
    grid-template-columns: repeat(12, minmax(0, 1fr));
  }

  .donation-grid > .section[data-component="StatusAndRevisionHeader"],
  .donation-grid > .section[data-component="KnownUnknownResponse"] {
    grid-column: 1 / -1;
  }

  .donation-grid > .section[data-component="GuidedFormSection"] {
    grid-column: span 8;
  }

  .donation-grid > .section[data-component="DecisionReceipt"] {
    grid-column: span 4;
  }

  .form-grid > .section[data-component="GuidedFormSection"] {
    grid-column: 1 / -1;
  }

  .form-grid > .section[data-component="StatusAndRevisionHeader"],
  .section-grid > .section[data-component="SignalTriagePanel"] {
    grid-column: 1 / -1;
  }

  .section {
    min-width: 0;
    padding: 0.625rem 0;
    border-top: 1px solid var(--paper-200);
    scroll-margin-top: 7.5rem;
  }

  .section.primary {
    border-top-color: var(--blue-100);
  }

  .section-content {
    min-width: 0;
  }

  .form-section:first-child,
  .workspace-section:first-child {
    padding-top: 0;
    border-top: 0;
  }

  @media (max-width: 1100px) {
    .section-grid {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }

    .donation-grid {
      grid-template-columns: repeat(8, minmax(0, 1fr));
    }

    .donation-grid > .section[data-component="GuidedFormSection"] {
      grid-column: span 5;
    }

    .donation-grid > .section[data-component="DecisionReceipt"] {
      grid-column: span 3;
    }
  }

  @media (max-width: 620px) {
    .section-grid {
      grid-template-columns: minmax(0, 1fr);
    }

    .donation-grid > .section[data-component="GuidedFormSection"],
    .donation-grid > .section[data-component="DecisionReceipt"] {
      grid-column: 1 / -1;
    }

    .section {
      padding: 0.75rem 0;
    }

  }
</style>
