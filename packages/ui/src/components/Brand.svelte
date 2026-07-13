<script lang="ts">
let { label = "구린네" }: { label?: string } = $props();
</script>

<a class="brand" href="/" aria-label="구린네 홈">
  <span class="brand-mark" aria-hidden="true"></span>
  <span class="brand-text">{label}</span>
</a>
