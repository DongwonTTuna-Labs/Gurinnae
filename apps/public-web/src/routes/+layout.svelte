<script lang="ts">
import "@gurine/ui/styles.css";
import PublicAppShell from "$lib/components/PublicAppShell.svelte";

let { children } = $props();
</script>

<svelte:head><meta name="viewport" content="width=device-width, initial-scale=1" /></svelte:head>
<PublicAppShell>{@render children()}</PublicAppShell>
