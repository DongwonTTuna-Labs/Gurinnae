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
      {#each navItems as [href, label]}
        {#if href === "/agencies"}
          <div class="public-nav-group">
            <a href={href} aria-current={current(href) ? "page" : undefined}>{label}</a>
            <a class="public-nav-child" href="/suppliers" aria-current={current("/suppliers") ? "page" : undefined}>업체</a>
          </div>
        {:else}
          <a href={href} aria-current={current(href) ? "page" : undefined}>{label}</a>
        {/if}
      {/each}
    </nav>
    <div class="header-actions">
      <a class="icon-button" href="/search" aria-label="검색">검색</a>
      <a class="subscribe-link" href="/subscribe">업데이트 구독</a>
      <details class="mobile-nav" bind:this={mobileNav} bind:open={mobileNavOpen} ontoggle={() => { mobileNavOpen = mobileNav?.open ?? false; }}>
        <summary class="icon-button" aria-label={mobileNavOpen ? "주요 탐색 닫기" : "주요 탐색 열기"} aria-expanded={mobileNavOpen} aria-controls="mobile-primary-nav" onclick={(event) => { mobileNavOpener = event.currentTarget as HTMLElement; }} onkeydown={handleMobileNavKeydown}>메뉴</summary>
        <nav id="mobile-primary-nav" aria-label="모바일 주요 탐색">
          {#each navItems as [href, label]}
            <a href={href} aria-current={current(href) ? "page" : undefined} onclick={() => closeMobileNav(false)}>{label}</a>
            {#if href === "/agencies"}<a class="public-nav-child" href="/suppliers" aria-current={current("/suppliers") ? "page" : undefined} onclick={() => closeMobileNav(false)}>업체</a>{/if}
          {/each}
        </nav>
      </details>
    </div>
  </div>
</header>

<style>
.status-strip {
  padding: 6px 24px;
  border-bottom: 1px solid var(--paper-200);
  background: var(--amber-50);
  color: var(--amber-900);
  font-size: 0.8125rem;
}
.status-strip-inner {
  max-width: var(--max);
  margin: 0 auto;
  display: flex;
  gap: 8px;
  align-items: center;
}
.status-dot {
  width: 7px; height: 7px;
  flex: none;
  border-radius: 50%;
  background: var(--amber-500);
}
.public-header {
  position: sticky;
  top: 0;
  z-index: 30;
  height: 54px;
  border-bottom: 1px solid var(--paper-200);
  background: var(--paper-25);
}
.header-inner {
  max-width: var(--max);
  height: 100%;
  margin: 0 auto;
  padding: 0 24px;
  display: grid;
  grid-template-columns: auto minmax(0, 1fr) auto;
  gap: 20px;
  align-items: center;
}
.public-nav,
.public-nav-group,
.header-actions {
  display: flex;
  align-items: center;
}
.public-nav {
  justify-content: center; gap: 8px;
}
.public-nav-group,
.header-actions {
  gap: 8px;
}
.public-nav a,
.subscribe-link {
  min-height: 44px; display: inline-flex; align-items: center;
  color: var(--ink-700);
  font-size: 0.8125rem;
  font-weight: 650;
  text-decoration: none;
}
.public-nav a {
  padding: 0 7px;
}
.public-nav a[aria-current="page"],
.subscribe-link:hover,
.subscribe-link:focus-visible {
  color: var(--blue-700);
  text-decoration: underline;
  text-underline-offset: 4px;
}
.public-nav-child {
  color: var(--ink-500);
  font-size: 0.75rem;
  text-decoration: underline;
  text-underline-offset: 3px;
}
.icon-button {
  min-width: var(--target-min);
  padding-inline: 8px;
  min-height: var(--target-min);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border: 1px solid var(--paper-200);
  border-radius: var(--radius-sm);
  background: var(--paper-0);
  color: var(--ink-900);
  font: inherit;
  text-decoration: none;
  cursor: pointer;
}
.mobile-nav {
  position: relative; display: none;
}
.mobile-nav summary { list-style: none; }
.mobile-nav summary::-webkit-details-marker { display: none; }
.mobile-nav[open] nav {
  position: absolute;
  top: calc(100% + 6px);
  right: 0;
  z-index: 30;
  min-width: 190px;
  padding: 6px;
  display: grid;
  gap: 1px;
  border: 1px solid var(--paper-200);
  border-radius: var(--radius-sm);
  background: var(--paper-0);
}
.mobile-nav nav a {
  min-height: 44px;
  padding: 0 10px;
  display: flex;
  align-items: center;
  border-radius: var(--radius-sm);
  color: var(--ink-900);
  font-size: 0.8125rem;
  text-decoration: none;
}
.mobile-nav nav a:hover,
.mobile-nav nav a:focus-visible {
  background: var(--blue-50);
}
.mobile-nav nav .public-nav-child {
  padding-left: 18px;
  color: var(--ink-500);
}
@media (max-width: 820px) {
  .public-nav { display: none; }
  .header-inner { grid-template-columns: 1fr auto; }
  .mobile-nav { display: block; }
}
@media (max-width: 620px) {
  .header-inner {
    padding: 0 14px;
    gap: 10px;
  }
  .subscribe-link {
    display: none;
  }
  .status-strip {
    padding-inline: 14px;
  }
}
</style>
