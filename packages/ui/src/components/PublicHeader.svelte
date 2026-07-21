<script lang="ts">
import { onMount } from "svelte";
import type { ScreenRuntime } from "../index";
import Brand from "./Brand.svelte";

let { runtime }: { runtime: ScreenRuntime } = $props();
const degraded = $derived(
  [
    "partial",
    "partial-failure",
    "stale",
    "error",
    "server-error",
    "incident",
    "degraded",
    "telemetry-gap",
  ].includes(runtime.state),
);
let mobileNav: HTMLDetailsElement;
let mobileNavOpen = $state(false);
let mobileNavOpener: HTMLElement | undefined;
const navItems = [
  ["/cases", "사례"],
  ["/contracts", "계약"],
  ["/agencies", "기관·업체"],
  ["/methodology", "방법론"],
  ["/coverage", "데이터 범위"],
  ["/corrections", "정정"],
] as const;
const currentPath = $derived(
  runtime.pathname ??
    (typeof window === "undefined" ? "" : window.location.pathname),
);
const current = (path: string) =>
  currentPath === path || currentPath.startsWith(`${path}/`);
function closeMobileNav(restoreFocus = true): void {
  if (!mobileNavOpen) return;
  mobileNavOpen = false;
  if (mobileNav) mobileNav.open = false;
  if (restoreFocus && mobileNavOpener?.isConnected) mobileNavOpener.focus();
}
function handleMobileNavKeydown(event: KeyboardEvent): void {
  if (event.key === "Escape") {
    event.preventDefault();
    closeMobileNav();
  }
}
onMount(() => {
  const previousOverflow = document.body.style.overflow;
  const syncScrollLock = () => {
    document.body.style.overflow = mobileNavOpen ? "hidden" : previousOverflow;
  };
  syncScrollLock();
  const onDocumentKeydown = (event: KeyboardEvent) => {
    if (event.key === "Escape") closeMobileNav();
  };
  document.addEventListener("keydown", onDocumentKeydown);
  return () => {
    document.body.style.overflow = previousOverflow;
    document.removeEventListener("keydown", onDocumentKeydown);
  };
});
$effect(() => {
  if (typeof document !== "undefined")
    document.body.style.overflow = mobileNavOpen ? "hidden" : "";
});
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
      {#each navItems as [href, label]}<a href={href} aria-current={current(href) ? "page" : undefined}>{label}</a>{/each}
    </nav>
    <div class="header-actions">
      <a class="icon-button" href="/search" aria-label="검색">⌕</a>
      <a class="secondary-button subscribe-link" href="/subscribe">업데이트 구독</a>
      <details class="mobile-nav" bind:this={mobileNav} bind:open={mobileNavOpen} ontoggle={() => { mobileNavOpen = mobileNav?.open ?? false; }}>
        <summary class="icon-button" aria-label={mobileNavOpen ? "주요 탐색 닫기" : "주요 탐색 열기"} aria-expanded={mobileNavOpen} aria-controls="mobile-primary-nav" onclick={(event) => { mobileNavOpener = event.currentTarget as HTMLElement; }} onkeydown={handleMobileNavKeydown} >☰</summary>
        <nav id="mobile-primary-nav" aria-label="모바일 주요 탐색">{#each navItems as [href, label]}<a href={href} aria-current={current(href) ? "page" : undefined} onclick={() => closeMobileNav(false)}>{label}</a>{/each}</nav>
      </details>
    </div>
  </div>
</header>
