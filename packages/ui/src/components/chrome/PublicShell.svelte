<script lang="ts">
import type {
  ScreenRuntime,
  ScreenViewModel,
  TypedScreenViewModel,
} from "../../index";
import {
  isBusyState,
  sourceSectionForId,
  statusSectionIdForScreen,
} from "../../screen-chrome";
import type { ScreenProjection } from "../../screen-projection";
import PublicHeader from "../PublicHeader.svelte";
import ScreenSection from "../ScreenSection.svelte";
import ScreenHeading from "../screen/ScreenHeading.svelte";
import SectionList from "../screen/SectionList.svelte";
import StateBadge from "../screen/StateBadge.svelte";
import StateSummary from "../screen/StateSummary.svelte";
import PublicFooter from "./PublicFooter.svelte";

let {
  screen,
  runtime,
  contract,
  projection,
}: {
  screen: ScreenViewModel;
  runtime: ScreenRuntime;
  contract: TypedScreenViewModel;
  projection: ScreenProjection;
} = $props();
const home = $derived(screen.id === "PUB-001");
const evidenceLanding = $derived(screen.archetype === "EVIDENCE_LANDING");
const statusSectionId = $derived(statusSectionIdForScreen(screen.sections));
const busy = $derived(isBusyState(runtime.state));
</script>

<div class="shell public-shell">
  <PublicHeader {runtime} />
            <main id="main-content" data-testid={projection.focus.main} data-focus-target={projection.focus.main} class="main public-main" data-screen-id={screen.id} data-archetype={screen.archetype} aria-busy={busy}>
    {#if evidenceLanding && statusSectionId}
      {@const statusSection = sourceSectionForId(screen, statusSectionId)}
      <section id={statusSection.id} tabindex="-1" aria-labelledby={`section-${statusSection.id}-heading`} data-testid={statusSection.test_id} data-focus-target={projection.sections[statusSection.id]?.focusTarget} data-component={statusSection.component} data-projection-state={projection.sections[statusSection.id]?.state} class="section pre-title-status">
        <div class="section-content"><ScreenSection section={statusSection} {screen} {runtime} index={0} projection={projection.sections[statusSection.id]} /></div>
      </section>
    {/if}
    {#if evidenceLanding}<StateBadge variant="live" {screen} {runtime} {projection} /><StateSummary {screen} {runtime} {projection} />{/if}
    <ScreenHeading variant={home ? "public-home" : "public"} {screen} {runtime} {contract} {projection} />
    {#if !evidenceLanding}<StateBadge variant="live" {screen} {runtime} {projection} /><StateSummary {screen} {runtime} {projection} />{/if}
    <SectionList {screen} {runtime} {contract} {projection} skipStatus={evidenceLanding} />
  </main>
  <PublicFooter />
</div>

<style>
.public-shell {
  min-height: 100vh;
  display: flex;
  flex-direction: column;
}

.public-main {
  width: 100%;
  max-width: var(--max);
  margin: 0 auto;
  padding: 16px 24px 40px;
  flex: 1;
  overflow-wrap: anywhere;
}

.pre-title-status {
  margin-bottom: 6px;
  padding-top: 0;
  border-top: 0;
}

.section-content {
  min-width: 0;
}

.pre-title-status .section-content {
  display: grid;
  grid-template-columns: minmax(12rem, 0.7fr) minmax(0, 1.3fr);
  grid-template-rows: auto auto auto;
  column-gap: 16px;
  align-items: center;
}

.pre-title-status .section-content :global(.section-heading) {
  grid-column: 1;
  grid-row: 1 / span 3;
}

.pre-title-status .section-content :global(.status-revision-grid) {
  grid-column: 2;
  grid-row: 1 / span 3;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  margin-top: 0;
}

.pre-title-status .section-content :global(.status-revision-grid p) {
  padding: 6px 8px;
}

.pre-title-status .section-content :global(.status-revision-grid p + p) {
  border-top: 0;
  border-left: 1px solid var(--paper-200);
}

.pre-title-status .section-content :global(.status-revision-grid strong) {
  margin-top: 2px;
}

@media (max-width: 620px) {
  .public-main {
    padding: 12px 16px 32px;
  }

  .pre-title-status {
    margin-bottom: 8px;
  }

  .pre-title-status .section-content {
    grid-template-columns: minmax(0, 1fr);
    grid-template-rows: auto;
    row-gap: 2px;
  }

  .pre-title-status .section-content :global(.section-heading),
  .pre-title-status .section-content :global(.status-revision-grid) {
    grid-column: 1;
    grid-row: auto;
  }

  .pre-title-status .section-content :global(.status-revision-grid) {
    grid-template-columns: minmax(0, 1fr);
    margin-top: 4px;
  }

  .pre-title-status .section-content :global(.status-revision-grid p) {
    padding: 5px 0;
    display: grid;
    grid-template-columns: minmax(7rem, 0.45fr) minmax(0, 1fr);
    gap: 8px;
    align-items: baseline;
  }

  .pre-title-status .section-content :global(.status-revision-grid p + p) {
    border-top: 1px solid var(--paper-200);
    border-left: 0;
  }

  .pre-title-status .section-content :global(.status-revision-grid strong) {
    margin-top: 0;
  }
}
</style>
