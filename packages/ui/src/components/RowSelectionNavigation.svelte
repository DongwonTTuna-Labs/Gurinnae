<script lang="ts">
import type { RowSelectionNavigationOption } from "../row-selection-navigation";

let {
  actionId,
  actionLabel,
  options,
  buttonClass,
  external = false,
}: {
  actionId: string;
  actionLabel: string;
  options: readonly RowSelectionNavigationOption[];
  buttonClass: string;
  external?: boolean;
} = $props();

let selectedIndex = $state(0);
const selected = $derived(options[selectedIndex] ?? options[0]);
</script>

{#if options.length > 0 && selected}
  <div class="row-selection-navigation">
    <label for={`action-${actionId}-target`}>
      <span>{actionLabel} 대상</span>
      <select id={`action-${actionId}-target`} bind:value={selectedIndex}>
        {#each options as option, index (option.href)}
          <option value={index}>{option.label}</option>
        {/each}
      </select>
    </label>
    <a
      id={`action-${actionId}`}
      class={`${buttonClass} navigation-action`}
      href={selected.href}
      target={external ? "_blank" : undefined}
      rel={external ? "noopener noreferrer" : undefined}
      data-action-id={actionId}
    >{actionLabel}</a>
  </div>
{/if}

<style>
  .row-selection-navigation {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    gap: 0.375rem 0.75rem;
    align-items: end;
    min-width: 0;
    padding-block: 0.5rem;
    border-top: 1px solid var(--paper-200);
  }
  label {
    display: grid;
    gap: 0.25rem;
    min-width: 0;
    color: var(--ink-900);
    font-size: 0.8125rem;
    font-weight: 650;
  }
  select {
    min-width: 0;
  }
  .navigation-action {
    align-self: end;
    justify-self: start;
  }
  @media (max-width: 620px) {
    .row-selection-navigation {
      grid-template-columns: minmax(0, 1fr);
    }
    label,
    .navigation-action {
      min-height: 44px;
    }
  }
  @media (forced-colors: active) {
    .row-selection-navigation {
      border-color: CanvasText;
    }
  }
</style>
