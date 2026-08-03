<script lang="ts">
import Brand from "./Brand.svelte";

let { requestLabel = "보호된 요청" }: { requestLabel?: string } = $props();
</script>

<header class="response-header"><Brand label="구린네 소명 포털" /><span>{requestLabel}</span><nav aria-label="소명 지원"><a href="/respond/unavailable#security">보안 도움말</a><a href="/respond/unavailable#contact">요청 담당자에게 문의</a></nav></header>
