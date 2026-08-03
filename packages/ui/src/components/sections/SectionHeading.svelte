<script lang="ts">
import type { ScreenSection } from "../../index";

let { section, kicker }: { section: ScreenSection; kicker?: string } = $props();
</script>

<div class="section-heading">
  {#if kicker}<p class="component-kicker">{kicker}</p>{/if}
  <h2 id={`section-${section.id}-heading`}>{section.title}</h2>
  <p class="section-purpose">{section.purpose}</p>
</div>

<style>
  .section-heading {
    display: flex;
    flex-wrap: wrap;
    gap: 0.125rem 0.5rem;
    align-items: baseline;
    margin-bottom: 0.375rem;
  }

  .component-kicker {
    margin: 0;
    color: var(--blue-700);
    font-size: var(--text-meta, 0.75rem);
    font-weight: 650;
    line-height: 1.3;
  }

  h2 {
    margin: 0;
    font-size: var(--text-h2, 1.0625rem);
    font-weight: 650;
    line-height: 1.25;
    letter-spacing: -0.015em;
  }

  .section-purpose {
    min-width: 12rem;
    margin: 0;
    flex: 1 1 16rem;
    color: var(--ink-500);
    font-size: var(--text-meta, 0.75rem);
    line-height: 1.3;
  }
</style>
