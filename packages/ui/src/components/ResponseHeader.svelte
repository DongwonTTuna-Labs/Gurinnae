<script lang="ts">
import Brand from "./Brand.svelte";

let { requestLabel = "보호된 요청" }: { requestLabel?: string } = $props();
</script>

<header class="response-header"><Brand label="구린네 소명 포털" /><span>{requestLabel}</span></header>
