<script lang="ts">
import Brand from "./Brand.svelte";

let {
  pathname = "",
  actorLabel = "로그인 필요",
}: { pathname?: string; actorLabel?: string } = $props();
const active = (prefix: string) =>
  pathname === prefix || pathname.startsWith(`${prefix}/`);
const exact = (path: string) => pathname === path;
</script>

<aside class="sidebar" aria-label="내부 작업 탐색">
  <Brand />
  <nav aria-label="내부 주요 탐색">
    <span class="nav-label">업무</span>
    <a aria-label="대시보드" aria-current={active("/internal/dashboard") ? "page" : undefined} class:active={active("/internal/dashboard")} href="/internal/dashboard">▣ <span>대시보드</span></a>
    <a aria-label="내 작업" aria-current={active("/internal/my-work") ? "page" : undefined} class:active={active("/internal/my-work")} href="/internal/my-work">✓ <span>내 작업</span></a>
    <span class="nav-label">조사</span>
    <a aria-label="신호" aria-current={active("/internal/signals") ? "page" : undefined} class:active={active("/internal/signals")} href="/internal/signals">◫ <span>신호</span></a>
    <a aria-label="사건" aria-current={active("/internal/cases") ? "page" : undefined} class:active={active("/internal/cases")} href="/internal/cases">▤ <span>사건</span></a>
    <span class="nav-label">검토·정정</span>
    <a aria-label="검토" aria-current={active("/internal/review") ? "page" : undefined} class:active={active("/internal/review")} href="/internal/review">◇ <span>검토</span></a>
    <a aria-label="정정" aria-current={active("/internal/corrections") ? "page" : undefined} class:active={active("/internal/corrections")} href="/internal/corrections">↺ <span>정정</span></a>
    <span class="nav-label">데이터</span>
    <a aria-label="출처" aria-current={active("/internal/sources") ? "page" : undefined} class:active={active("/internal/sources")} href="/internal/sources">◎ <span>출처</span></a>
    <a aria-label="규칙과 작업" aria-current={active("/internal/rules") ? "page" : undefined} class:active={active("/internal/rules")} href="/internal/rules">⚙ <span>규칙·작업</span></a>
    <span class="nav-label">운영</span>
    <a aria-label="감사" aria-current={active("/internal/audit") ? "page" : undefined} class:active={active("/internal/audit")} href="/internal/audit">☷ <span>감사</span></a>
    <a aria-label="예산" aria-current={active("/internal/operations/budgets") ? "page" : undefined} class:active={active("/internal/operations/budgets")} href="/internal/operations/budgets">₩ <span>예산</span></a>
    <a aria-label="공급자" aria-current={active("/internal/operations/providers") ? "page" : undefined} class:active={active("/internal/operations/providers")} href="/internal/operations/providers">⇄ <span>공급자</span></a>
    <a aria-label="작업 큐" aria-current={active("/internal/operations/jobs") ? "page" : undefined} class:active={active("/internal/operations/jobs")} href="/internal/operations/jobs">▤ <span>작업 큐</span></a>
    <a aria-label="운영 건강" aria-current={exact("/internal/operations") ? "page" : undefined} class:active={exact("/internal/operations")} href="/internal/operations">♥ <span>운영 건강</span></a>
    <a aria-label="킬 스위치" aria-current={active("/internal/operations/kill-switches") ? "page" : undefined} class:active={active("/internal/operations/kill-switches")} href="/internal/operations/kill-switches">■ <span>킬 스위치</span></a>
    <span class="nav-label">접근 관리</span>
    <a aria-label="관리자" aria-current={active("/internal/admin/users") || active("/internal/admin/roles") ? "page" : undefined} class:active={active("/internal/admin/users") || active("/internal/admin/roles")} href="/internal/admin/users">⚿ <span>관리자</span></a>
    <a aria-label="역할" aria-current={active("/internal/admin/roles") ? "page" : undefined} class:active={active("/internal/admin/roles")} href="/internal/admin/roles">♙ <span>역할</span></a>
    <span class="nav-label">유틸리티</span>
    <a aria-label="내부 검색" aria-current={active("/internal/search") ? "page" : undefined} class:active={active("/internal/search")} href="/internal/search">⌕ <span>내부 검색</span></a>
    <a aria-label="알림" aria-current={active("/internal/notifications") ? "page" : undefined} class:active={active("/internal/notifications")} href="/internal/notifications">! <span>알림</span></a>
    <a aria-label="계정" aria-current={active("/internal/account") ? "page" : undefined} class:active={active("/internal/account")} href="/internal/account">◎ <span>계정</span></a>
  </nav>
  <div class="sidebar-user"><strong>현재 세션</strong><span>{actorLabel}</span></div>
</aside>
