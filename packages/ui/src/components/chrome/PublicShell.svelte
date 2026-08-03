<script lang="ts">
import type {
  ScreenRuntime,
  ScreenViewModel,
  TypedScreenViewModel,
} from "../../index";
import { publicActionPlacement } from "../../public-action-placement";
import {
  isBusyState,
  sourceSectionForId,
  statusSectionIdForScreen,
} from "../../screen-chrome";
import type { ScreenProjection } from "../../screen-projection";
import ArchetypeAssembly from "../archetypes/ArchetypeAssembly.svelte";
import ProjectionValue from "../ProjectionValue.svelte";
import PublicDetailStatusContext from "../PublicDetailStatusContext.svelte";
import PublicHeader from "../PublicHeader.svelte";
import ScreenActions from "../ScreenActions.svelte";
import ScreenSection from "../ScreenSection.svelte";
import ScreenHeading from "../screen/ScreenHeading.svelte";
import StateBadge from "../screen/StateBadge.svelte";
import StateSummary from "../screen/StateSummary.svelte";
import Breadcrumb from "./Breadcrumb.svelte";
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
const publicCaseDetail = $derived(screen.id === "PUB-004");
const evidenceLanding = $derived(screen.archetype === "EVIDENCE_LANDING");
const statusSectionId = $derived(statusSectionIdForScreen(screen.sections));
const busy = $derived(isBusyState(runtime.state));
const actionPlacement = $derived(publicActionPlacement(screen));
type PublicCaseField = Readonly<{
  name: string;
  label: string;
  value: string | number;
}>;
const publicCaseMetaFields = $derived.by((): PublicCaseField[] => {
  const lead = publicCaseDetail ? runtime.publicCaseLead : undefined;
  if (!lead) return [];
  return [
    { name: "slug", label: "사건 식별자", value: lead.slug },
    { name: "revision", label: "개정본", value: lead.revision },
    ...(lead.agencyName
      ? [{ name: "agencyName", label: "기관명", value: lead.agencyName }]
      : []),
    ...(lead.contractName
      ? [
          {
            name: "contractName",
            label: "계약명",
            value: lead.contractName,
          },
        ]
      : []),
  ];
});
const publicCaseStatFields = $derived.by((): PublicCaseField[] => {
  const lead = publicCaseDetail ? runtime.publicCaseLead : undefined;
  if (!lead) return [];
  return [
    ...(lead.amountLabel
      ? [{ name: "amount", label: "계약 금액", value: lead.amountLabel }]
      : []),
    {
      name: "confirmedCount",
      label: "확인",
      value: lead.confirmedCount,
    },
    { name: "unknownCount", label: "미확인", value: lead.unknownCount },
    { name: "responseCount", label: "소명", value: lead.responseCount },
    { name: "publishedAt", label: "공개 시각", value: lead.publishedAt },
    { name: "updatedAt", label: "갱신 시각", value: lead.updatedAt },
    {
      name: "freshnessAsOf",
      label: "자료 기준 시각",
      value: lead.freshnessAsOf,
    },
  ];
});
const publicCaseTitle = $derived(runtime.publicCaseLead?.title ?? screen.title);
const publicCaseSummary = $derived(runtime.publicCaseLead?.summary ?? null);
const publicStatusContext = $derived(runtime.publicStatusContext);
</script>

<div class="shell public-shell">
  <PublicHeader {runtime} />
            <main id="main-content" data-testid={projection.focus.main} data-focus-target={projection.focus.main} class="main public-main" class:public-case-detail={publicCaseDetail} class:public-status-detail={publicStatusContext !== undefined} data-screen-id={screen.id} data-archetype={screen.archetype} aria-busy={busy}>
    {#if publicCaseDetail && statusSectionId}
      {@const statusSection = sourceSectionForId(screen, statusSectionId)}
      <Breadcrumb {screen} {runtime} />
      {#if publicCaseMetaFields.length > 0}
        <dl class="public-case-meta" aria-label="사건 공개 기준">
          {#each publicCaseMetaFields as field (field.name)}
            <div><dt>{field.label}</dt><dd><ProjectionValue name={field.name} label={field.label} value={field.value} /></dd></div>
          {/each}
        </dl>
      {/if}
      <header class="public-case-heading" data-journey={contract.journey}>
        <h1 id={`${screen.id.toLowerCase()}__heading`} data-testid={projection.focus.heading} data-focus-target={projection.focus.heading}>{publicCaseTitle}</h1>
        {#if publicCaseSummary}<p>{publicCaseSummary}</p>{/if}
        {#if publicStatusContext}<PublicDetailStatusContext context={publicStatusContext} showSubject={false} />{/if}
      </header>
      <section id={statusSection.id} tabindex="-1" aria-labelledby={`section-${statusSection.id}-heading`} data-testid={statusSection.test_id} data-focus-target={projection.sections[statusSection.id]?.focusTarget} data-component={statusSection.component} data-projection-state={projection.sections[statusSection.id]?.state} class="section pre-title-status">
        <div class="public-case-status-heading"><h2 id={`section-${statusSection.id}-heading`}>{statusSection.title}</h2><p>{statusSection.purpose}</p></div>
        {#if publicCaseStatFields.length > 0}
          <dl class="public-case-stats">
            {#each publicCaseStatFields as field (field.name)}
              <div><dt>{field.label}</dt><dd><ProjectionValue name={field.name} label={field.label} value={field.value} /></dd></div>
            {/each}
          </dl>
        {:else}<p class="public-case-status-empty" role="status">상태 정보를 불러오는 중입니다.</p>{/if}
      </section>
      <ScreenActions {screen} {runtime} actionIds={actionPlacement?.headerActionIds ?? []} attachments={false} context="header" />
      <StateBadge variant="live" {screen} {runtime} {projection} /><StateSummary {screen} {runtime} {projection} />
    {:else}
      {#if evidenceLanding && statusSectionId}
        {@const statusSection = sourceSectionForId(screen, statusSectionId)}
        <section id={statusSection.id} tabindex="-1" aria-labelledby={`section-${statusSection.id}-heading`} data-testid={statusSection.test_id} data-focus-target={projection.sections[statusSection.id]?.focusTarget} data-component={statusSection.component} data-projection-state={projection.sections[statusSection.id]?.state} class="section pre-title-status">
          <div class="section-content"><ScreenSection section={statusSection} {screen} {runtime} index={0} projection={projection.sections[statusSection.id]} /></div>
        </section>
      {/if}
      {#if evidenceLanding}<StateBadge variant="live" {screen} {runtime} {projection} /><StateSummary {screen} {runtime} {projection} />{/if}
      <ScreenHeading variant={home ? "public-home" : "public"} {screen} {runtime} {contract} {projection} />
      {#if publicStatusContext}<PublicDetailStatusContext context={publicStatusContext} />{/if}
      <ScreenActions {screen} {runtime} actionIds={actionPlacement?.headerActionIds ?? []} attachments={false} context="header" />
      {#if !evidenceLanding}<StateBadge variant="live" {screen} {runtime} {projection} /><StateSummary {screen} {runtime} {projection} />{/if}
    {/if}
    <ArchetypeAssembly {screen} {runtime} {contract} {projection} skipStatus={evidenceLanding} />
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

@media (min-width: 1101px) {
  .public-main:is(.public-case-detail, .public-status-detail) {
    padding-bottom: 16px;
  }
}

.pre-title-status {
  margin-bottom: 6px;
  padding-top: 0;
  border-top: 0;
}

.public-case-meta,
.public-case-stats {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(9rem, 1fr));
  gap: 1px;
  margin: 0 0 8px;
  border-block: 1px solid var(--paper-200);
  background: var(--paper-200);
}

.public-case-meta > div,
.public-case-stats > div {
  min-width: 0;
  padding: 5px 8px;
  background: var(--paper-0);
}

.public-case-meta dt,
.public-case-stats dt {
  color: var(--ink-500);
  font-size: 0.75rem;
  font-weight: 650;
}

.public-case-meta dd,
.public-case-stats dd {
  margin: 1px 0 0;
  color: var(--ink-900);
  font-size: 0.875rem;
  font-weight: 650;
}

.public-case-heading {
  margin-bottom: 0;
}

.public-case-heading h1,
.public-case-status-heading :is(h2, p),
.public-case-heading p,
.public-case-status-empty {
  margin: 0;
}

.public-case-heading h1 {
  color: var(--ink-950);
  font-size: var(--text-h1, clamp(1.5rem, 2vw, 1.875rem));
  line-height: 1.2;
  letter-spacing: -0.025em;
}

.public-case-heading p,
.public-case-status-heading p,
.public-case-status-empty {
  color: var(--ink-700);
  font-size: 0.8125rem;
  line-height: 1.45;
}

.public-case-status-heading {
  display: flex;
  flex-wrap: wrap;
  gap: 3px 8px;
  align-items: baseline;
  margin-bottom: 6px;
}

.public-case-status-heading h2 {
  font-size: var(--text-h2, 1.0625rem);
  line-height: 1.25;
}

.public-case-status-heading p {
  flex: 1 1 16rem;
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
