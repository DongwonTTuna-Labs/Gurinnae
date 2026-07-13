<script lang="ts">
import type { ScreenRuntime } from "../index";
import Brand from "./Brand.svelte";

let { runtime }: { runtime: ScreenRuntime } = $props();
const degraded = $derived(
  ["partial", "stale", "error"].includes(runtime.state),
);
</script>

{#if degraded}
  <div class="status-strip" role="status">
    <div class="status-strip-inner"><span class="status-dot" aria-hidden="true"></span>일부 자료의 최신성 또는 이용 상태를 확인하고 있습니다.</div>
  </div>
{/if}
<header class="public-header">
  <div class="header-inner">
    <Brand />
    <nav class="public-nav" aria-label="주요 탐색">
      <a href="/cases">사례</a><a href="/contracts">계약</a><a href="/agencies">기관·업체</a>
      <a href="/methodology">방법론</a><a href="/coverage">데이터 범위</a><a href="/corrections">정정</a>
    </nav>
    <div class="header-actions">
      <a class="icon-button" href="/search" aria-label="검색">⌕</a>
      <a class="secondary-button subscribe-link" href="/subscribe">업데이트 구독</a>
      <a class="icon-button mobile-menu" href="#page-actions" aria-label="화면 작업으로 이동">☰</a>
    </div>
  </div>
</header>
