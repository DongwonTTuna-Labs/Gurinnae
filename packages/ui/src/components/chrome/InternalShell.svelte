<script lang="ts">
import type {
  ScreenRuntime,
  ScreenViewModel,
  TypedScreenViewModel,
} from "../../index";
import {
  isBusyState,
  isWorkspaceScreen,
  primaryActionAllowed,
  primaryTargetForAction,
} from "../../screen-chrome";
import { stateLabel } from "../../screen-contract";
import type { ScreenProjection } from "../../screen-projection";
import ArchetypeAssembly from "../archetypes/ArchetypeAssembly.svelte";
import InternalSidebar from "../InternalSidebar.svelte";
import ScreenHeading from "../screen/ScreenHeading.svelte";
import StateBadge from "../screen/StateBadge.svelte";
import StateSummary from "../screen/StateSummary.svelte";
import InternalContextRail from "./InternalContextRail.svelte";
import InternalTaskRail from "./InternalTaskRail.svelte";

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
const workspace = $derived(isWorkspaceScreen(screen, runtime.pathname ?? ""));
const actionAllowed = $derived(primaryActionAllowed(contract, runtime));
const primaryTarget = $derived(
  primaryTargetForAction(contract.primaryActionId),
);
const busy = $derived(isBusyState(runtime.state));
</script>
<div class="internal-shell">
  <InternalSidebar pathname={runtime.pathname ?? ""} actorLabel={runtime.actorDisplayName ?? "로그인 필요"} />
  <div class="internal-content">
    <header class="internal-topbar"><div class="topbar-pair"><span class="topbar-label">화면</span><strong>{screen.title}</strong></div><div class="topbar-pair"><span class="topbar-label">상태</span><StateBadge variant="topbar" {screen} {runtime} {projection} /></div></header>
    <main id="main-content" data-testid={projection.focus.main} data-focus-target={projection.focus.main} class="internal-main" data-screen-id={screen.id} data-archetype={screen.archetype} aria-busy={busy}>
      <header class="workspace-head"><div class="workspace-head-row"><div class="workspace-heading"><ScreenHeading variant="internal" {screen} {runtime} {contract} {projection} /><dl class="workspace-meta" aria-label="화면 메타데이터"><div class="meta-pair"><dt>여정</dt><dd><span class="badge info">{contract.journey}</span></dd></div><div class="meta-pair"><dt>역할</dt><dd><span class="badge neutral">{contract.persona}</span></dd></div><div class="meta-pair"><dt>대상</dt><dd>{contract.objectLabel}</dd></div><div class="meta-pair"><dt>현재 상태</dt><dd>{stateLabel(runtime.state)}</dd></div><div class="meta-pair"><dt>다음 행동</dt><dd>{contract.primaryActionLabel ?? "확인 필요"}</dd></div></dl></div>{#if actionAllowed && contract.primaryActionId}<a class="primary-button" href={primaryTarget}>{contract.primaryActionLabel ?? "다음 단계 열기"}</a>{:else if contract.primaryActionId}<span class="primary-button disabled" aria-disabled="true">권한 또는 상태 확인 필요</span>{/if}</div></header>
      <StateSummary {screen} {runtime} {projection} />
      {#if workspace}
        <div class="workspace-grid">
          <InternalTaskRail {screen} {runtime} />
          <div class="workspace-panel"><ArchetypeAssembly variant="workspace" {screen} {runtime} {contract} {projection} /></div>
          <InternalContextRail {screen} {runtime} {contract} />
        </div>
      {:else}<div class="workspace-panel operation-panel"><ArchetypeAssembly {screen} {runtime} {contract} {projection} /></div>{/if}
    </main>
  </div>
</div>
<style>
  .internal-shell {
    min-height: 100vh;
    display: grid;
    grid-template-columns: 14rem minmax(0, 1fr);
    background: var(--paper-50);
  }
  .internal-content {
    min-width: 0;
  }
  .internal-topbar {
    position: sticky;
    top: 0;
    z-index: 20;
    min-height: 3rem;
    padding: 0.375rem 1rem;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    border-bottom: 1px solid var(--paper-200);
    background: var(--paper-0);
    font-size: 0.8125rem;
  }
  .topbar-pair {
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 0.375rem;
  }
  .topbar-pair:first-child {
    overflow: hidden;
  }
  .topbar-pair strong {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .topbar-label,
  .workspace-meta dt {
    flex: none;
    color: var(--ink-500);
    font-size: 0.75rem;
    font-weight: 700;
  }
  .internal-main {
    max-width: 93.75rem;
    margin-inline: auto;
    padding: 0.75rem 1rem 2rem;
    overflow-wrap: anywhere;
  }
  .workspace-head {
    margin-bottom: 0.5rem;
    padding: 0.625rem 0.75rem;
    border: 1px solid var(--paper-200);
    border-radius: var(--radius-sm);
    background: var(--paper-0);
  }
  .workspace-head-row {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 1rem;
  }
  .workspace-heading {
    min-width: 0;
    flex: 1;
  }
  .workspace-meta {
    margin: 0.375rem 0 0;
    display: flex;
    align-items: center;
    gap: 0.625rem;
    overflow-x: auto;
    color: var(--ink-700);
    font-size: 0.8125rem;
    white-space: nowrap;
  }
  .meta-pair {
    padding: 0;
    display: inline-flex;
    flex: none;
    align-items: center;
    gap: 0.25rem;
    border: 0;
  }
  .workspace-meta dd {
    margin: 0;
  }
  .workspace-meta .badge {
    min-height: 1.375rem;
    padding: 0.125rem 0.375rem;
    border-radius: var(--radius-sm);
    font-size: 0.75rem;
  }
  .workspace-head-row > .primary-button {
    flex: none;
  }
  .workspace-grid {
    display: grid;
    grid-template-columns: 11.875rem minmax(0, 1fr) 17.5rem;
    gap: 0.75rem;
    align-items: start;
  }
  @media (min-width: 1101px) {
    .internal-main:is(
        [data-screen-id="INT-002"],
        [data-screen-id="CAS-005"],
        [data-screen-id="CAS-006"],
        [data-screen-id="CAS-009"],
        [data-screen-id="CAS-010"],
        [data-screen-id="CAS-011"],
        [data-screen-id="COR-002"]
      )
      > .workspace-grid {
      grid-template-columns: 7.5rem minmax(0, 1fr) 11rem;
    }

    .internal-main:is(
        [data-screen-id="INT-002"],
        [data-screen-id="CAS-010"],
        [data-screen-id="CAS-011"]
      )
      > .workspace-grid {
      grid-template-columns: 6rem minmax(0, 1fr) 9rem;
    }
  }
  .workspace-panel {
    min-width: 0;
    padding: 0.75rem;
    border: 1px solid var(--paper-200);
    border-radius: var(--radius-sm);
    background: var(--paper-0);
  }
  .operation-panel {
    max-width: 70rem;
  }
  @media (max-width: 1100px) {
    .workspace-grid {
      grid-template-columns: 11.25rem minmax(0, 1fr);
    }
  }
  @media (max-width: 820px) {
    .internal-shell {
      grid-template-columns: 4rem minmax(0, 1fr);
    }
    .internal-main {
      padding: 0.625rem 0.75rem 1.5rem;
    }
    .workspace-head-row {
      flex-direction: column;
      align-items: stretch;
    }
    .workspace-head-row > .primary-button {
      align-self: flex-start;
    }
    .workspace-grid {
      grid-template-columns: minmax(0, 1fr);
    }
  }
  @media (max-width: 620px) {
    .internal-shell {
      grid-template-columns: minmax(0, 1fr);
    }
    .internal-topbar {
      position: static;
      min-height: 3rem;
      padding-inline: 0.75rem;
    }
    .internal-main {
      padding: 0.625rem 0.75rem 1.5rem;
    }
    .workspace-head {
      padding: 0.625rem;
    }
    .workspace-head-row > .primary-button {
      width: 100%;
    }
    .workspace-grid {
      grid-template-columns: minmax(0, 1fr);
    }
    .workspace-panel {
      width: 100%;
      padding: 0.625rem;
    }
  }
</style>
