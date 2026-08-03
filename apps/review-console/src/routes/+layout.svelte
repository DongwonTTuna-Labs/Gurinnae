<script lang="ts">
import "@gurine/ui/styles.css";
import ReviewAppShell from "$lib/components/ReviewAppShell.svelte";

let { children } = $props();
</script>

<svelte:head><meta name="viewport" content="width=device-width, initial-scale=1" /></svelte:head>
<ReviewAppShell>{@render children()}</ReviewAppShell>
