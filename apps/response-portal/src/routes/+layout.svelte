<script lang="ts">
import "@gurine/ui/styles.css";
import ResponseAppShell from "$lib/components/ResponseAppShell.svelte";

let { children } = $props();
</script>

<svelte:head><meta name="viewport" content="width=device-width, initial-scale=1" /></svelte:head>
<ResponseAppShell>{@render children()}</ResponseAppShell>
