<script lang="ts">
import { tick } from "svelte";
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import PublicEvidenceRows from "./PublicEvidenceRows.svelte";
import RelayModelCatalogLedger from "./RelayModelCatalogLedger.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, screen, runtime, projection }: ScreenSectionProps = $props();
let evidenceDialog = $state<HTMLDialogElement>();
let evidenceHeading = $state<HTMLHeadingElement>();
let evidenceTrigger = $state<HTMLButtonElement>();
const isPublicEvidence = $derived(
  screen.id === "PUB-004" && section.id === "evidence",
);
const openEvidenceAction = $derived(
  screen.actions.find((action) => action.id === "open-evidence"),
);
const isRelayModelCatalog = $derived(
  screen.id === "OPS-005" && section.id === "model-catalog",
);
const publicClaimProjection = $derived(
  isPublicEvidence && projection
    ? {
        ...projection,
        fields: projection.fields.filter((field) => field.name === "claims"),
      }
    : null,
);

function openEvidenceDrawer() {
  if (!evidenceDialog || evidenceDialog.open) return;
  evidenceDialog.showModal();
  void tick().then(() => evidenceHeading?.focus());
}

function restoreEvidenceTrigger() {
  const trigger = evidenceTrigger;
  if (trigger?.isConnected && !trigger.disabled) {
    void tick().then(() => trigger.focus());
  }
}

function focusableDrawerControls(): HTMLElement[] {
  if (!evidenceDialog) return [];
  return Array.from(
    evidenceDialog.querySelectorAll<HTMLElement>(
      'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
    ),
  ).filter(
    (element) => !element.hasAttribute("hidden") && element.tabIndex >= 0,
  );
}

function trapEvidenceFocus(event: KeyboardEvent) {
  if (event.key !== "Tab") return;
  const controls = focusableDrawerControls();
  const first = controls[0];
  const last = controls.at(-1);
  if (!first || !last) {
    event.preventDefault();
    evidenceHeading?.focus();
    return;
  }
  const active = evidenceDialog?.ownerDocument.activeElement;
  if (active === evidenceHeading) {
    event.preventDefault();
    (event.shiftKey ? last : first).focus();
  } else if (event.shiftKey && active === first) {
    event.preventDefault();
    last.focus();
  } else if (!event.shiftKey && active === last) {
    event.preventDefault();
    first.focus();
  }
}
</script>

{#snippet evidenceContent()}
  {#if isPublicEvidence && runtime.publicEvidence}
    {#if publicClaimProjection && publicClaimProjection.fields.length > 0}<OperationData {runtime} projection={publicClaimProjection} mode="cards" emptyLabel="연결된 공개 주장이 없습니다." />{/if}
    <PublicEvidenceRows evidence={runtime.publicEvidence} />
  {:else if projection}
    <OperationData {runtime} {projection} mode="cards" emptyLabel="현재 범위에 연결된 검증 근거가 없습니다." />
  {/if}
{/snippet}

<SectionHeading {section} kicker="근거 원장" /><p class="evidence-note">보호 필드는 브라우저에 원문으로 표시하지 않습니다.</p>{#if isRelayModelCatalog}{#if runtime.relayModelCatalog}<RelayModelCatalogLedger catalog={runtime.relayModelCatalog} />{:else}<RelayModelCatalogLedger />{/if}{:else}{@render evidenceContent()}{/if}
{#if isPublicEvidence && openEvidenceAction}
  <div class="evidence-actions">
    <button
      bind:this={evidenceTrigger}
      type="button"
      class="primary-button evidence-trigger"
      data-action-id="open-evidence"
      data-testid="pub_004__action__open_evidence"
      aria-haspopup="dialog"
      aria-controls="pub-004-evidence-drawer"
      onclick={openEvidenceDrawer}
    >{openEvidenceAction.label}</button>
  </div>
  <dialog
    bind:this={evidenceDialog}
    id="pub-004-evidence-drawer"
    class="evidence-drawer"
    aria-modal="true"
    aria-labelledby="pub-004-evidence-drawer-heading"
    onkeydown={trapEvidenceFocus}
    onclose={restoreEvidenceTrigger}
  >
    <div class="evidence-drawer__body">
      <h2
        bind:this={evidenceHeading}
        id="pub-004-evidence-drawer-heading"
        data-testid="pub_004__evidence_drawer__heading"
        tabindex="-1"
      >{section.title}</h2>
      <div class="evidence-drawer__content">
        {@render evidenceContent()}
      </div>
      <form method="dialog" class="evidence-drawer__actions">
        <button type="submit" value="close" class="secondary-button">닫기</button>
      </form>
    </div>
  </dialog>
{/if}

<style>
  .evidence-note {
    margin: 0 0 0.625rem;
    padding: 0.375rem 0.625rem;
    border-left: 2px solid var(--amber-500);
    background: var(--amber-50);
    color: var(--amber-900);
    font-size: 0.8125rem;
    line-height: 1.4;
  }

  .evidence-actions {
    display: flex;
    margin-top: 0.625rem;
  }

  .evidence-trigger {
    min-height: 44px;
  }

  .evidence-drawer {
    position: fixed;
    inset: 0 0 0 auto;
    box-sizing: border-box;
    width: min(92vw, 42rem);
    max-width: none;
    height: 100dvh;
    max-height: none;
    margin: 0;
    padding: 0;
    overflow: hidden;
    border: 0;
    border-left: 1px solid var(--paper-200);
    border-radius: 0;
    background: var(--paper-0);
    color: var(--ink-950);
  }

  .evidence-drawer::backdrop {
    background: color-mix(in srgb, var(--ink-950) 48%, transparent);
  }

  .evidence-drawer__body {
    display: grid;
    grid-template-rows: auto minmax(0, 1fr) auto;
    height: 100%;
  }

  .evidence-drawer h2 {
    margin: 0;
    padding: 0.875rem 1rem;
    border-bottom: 1px solid var(--paper-200);
    font-size: 1.25rem;
    font-weight: 650;
  }

  .evidence-drawer__content {
    min-height: 0;
    padding: 0.75rem 1rem;
    overflow: auto;
  }

  .evidence-drawer__actions {
    display: flex;
    justify-content: flex-end;
    margin: 0;
    padding: 0.75rem 1rem;
    border-top: 1px solid var(--paper-200);
  }

  .evidence-drawer__actions button {
    min-height: 44px;
  }

  @media (max-width: 620px) {
    .evidence-drawer {
      width: 100vw;
    }
  }

  @media (forced-colors: active) {
    .evidence-note {
      border-color: CanvasText;
      background: Canvas;
      color: CanvasText;
    }

    .evidence-drawer {
      border-color: CanvasText;
      background: Canvas;
      color: CanvasText;
    }

    .evidence-drawer::backdrop {
      background: CanvasText;
      opacity: 0.65;
    }
  }
</style>
