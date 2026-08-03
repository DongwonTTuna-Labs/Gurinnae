<script lang="ts">
import Brand from "./Brand.svelte";

let { requestLabel = "보호된 요청" }: { requestLabel?: string } = $props();
</script>

<header class="response-header"><Brand label="구린네 소명 포털" /><span>{requestLabel}</span><nav aria-label="소명 지원"><a href="/respond/unavailable#security">보안 도움말</a><a href="/respond/unavailable#contact">요청 담당자에게 문의</a></nav></header>

<style>
.response-header {
  min-height: 52px;
  padding: 0 max(20px, calc((100vw - 1120px) / 2));
  display: grid;
  grid-template-columns: auto minmax(0, 1fr) auto;
  align-items: center;
  gap: 16px;
  background: var(--paper-0);
  border-bottom: 1px solid var(--paper-200);
}

.response-header > span {
  min-width: 0;
  color: var(--ink-500);
  font-size: 0.75rem;
  line-height: 1.4;
  overflow-wrap: anywhere;
}

.response-header nav {
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 12px;
}

.response-header nav a {
  display: inline-flex;
  align-items: center;
  min-height: var(--target-min);
  color: var(--blue-700);
  font-size: 0.8125rem;
  text-decoration: underline;
  text-underline-offset: 3px;
}

@media (max-width: 620px) {
  .response-header {
    min-height: 0;
    padding: 8px 14px;
    grid-template-columns: minmax(0, 1fr);
    gap: 2px;
    align-items: start;
  }

  .response-header nav {
    justify-content: flex-start;
    max-width: 100%;
  }
}
</style>
