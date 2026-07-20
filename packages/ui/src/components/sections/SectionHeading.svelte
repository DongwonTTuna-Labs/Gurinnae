<script lang="ts">
import type { ScreenSection } from "../../index";

let { section, kicker }: { section: ScreenSection; kicker?: string } = $props();
</script>

{#if kicker}<p class="component-kicker">{kicker}</p>{/if}
<h2 id={`section-${section.id}-heading`}>{section.title}</h2>
<p class="section-purpose">{section.purpose}</p>
