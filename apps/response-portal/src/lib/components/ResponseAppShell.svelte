<script lang="ts">
import type { Snippet } from "svelte";

let { children }: { children: Snippet } = $props();
</script>

<a class="skip-link" href="#main-content">본문으로 건너뛰기</a>
{@render children()}
