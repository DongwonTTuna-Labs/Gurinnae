<script lang="ts">
import Brand from "./Brand.svelte";

let {
  pathname = "",
  actorLabel = "로그인 필요",
}: { pathname?: string; actorLabel?: string } = $props();
const active = (prefix: string) => pathname.startsWith(prefix);
</script>

<aside class="sidebar" aria-label="내부 작업 탐색">
  <Brand />
  <nav aria-label="내부 주요 탐색">
    <span class="nav-label">작업</span>
    <a aria-label="대시보드" aria-current={active("/internal/dashboard") ? "page" : undefined} class:active={active("/internal/dashboard")} href="/internal/dashboard">▣ <span>대시보드</span></a>
    <a aria-label="내 작업" aria-current={active("/internal/my-work") ? "page" : undefined} class:active={active("/internal/my-work")} href="/internal/my-work">✓ <span>내 작업</span></a>
    <a aria-label="내부 검색" aria-current={active("/internal/search") ? "page" : undefined} class:active={active("/internal/search")} href="/internal/search">⌕ <span>내부 검색</span></a>
    <span class="nav-label">조사</span>
    <a aria-label="신호" aria-current={active("/internal/signals") ? "page" : undefined} class:active={active("/internal/signals")} href="/internal/signals">◫ <span>신호</span></a>
    <a aria-label="사건" aria-current={active("/internal/cases") ? "page" : undefined} class:active={active("/internal/cases")} href="/internal/cases">▤ <span>사건</span></a>
    <a aria-label="검토" aria-current={active("/internal/review") ? "page" : undefined} class:active={active("/internal/review")} href="/internal/review">◇ <span>검토</span></a>
    <span class="nav-label">운영</span>
    <a aria-label="출처" aria-current={active("/internal/sources") ? "page" : undefined} class:active={active("/internal/sources")} href="/internal/sources">◎ <span>출처</span></a>
    <a aria-label="규칙과 작업" aria-current={active("/internal/rules") ? "page" : undefined} class:active={active("/internal/rules")} href="/internal/rules">⚙ <span>규칙·작업</span></a>
    <a aria-label="감사" aria-current={active("/internal/audit") ? "page" : undefined} class:active={active("/internal/audit")} href="/internal/audit">☷ <span>감사</span></a>
  </nav>
  <div class="sidebar-user"><strong>현재 세션</strong><span>{actorLabel}</span></div>
</aside>
