<script lang="ts">
import type { ScreenRuntime, ScreenViewModel } from "../../index";
import { breadcrumbItemsForScreen } from "../../screen-chrome";

let { screen, runtime }: { screen: ScreenViewModel; runtime: ScreenRuntime } =
  $props();
const items = $derived(breadcrumbItemsForScreen(screen, runtime.pathname));
</script>

{#if items.length > 0}<nav class="breadcrumb" aria-label="현재 위치">{#each items as item, index}{#if index > 0}<span aria-hidden="true">/</span>{/if}{#if index < items.length - 1}<a href={item.href}>{item.label}</a>{:else}<span aria-current="page">{item.label}</span>{/if}{/each}</nav>{/if}

<style>
.breadcrumb {
  margin: 0 0 10px;
  display: flex;
  flex-wrap: wrap;
  gap: 4px 7px;
  align-items: center;
  color: var(--ink-500);
  font-size: 0.75rem;
  line-height: 1.4;
}

a {
  color: inherit;
  text-decoration-thickness: 1px;
  text-underline-offset: 3px;
}
</style>
