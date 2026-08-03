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
  <Brand variant="internal" />
  <nav aria-label="내부 주요 탐색">
    <span class="nav-label">업무</span>
    <a aria-label="대시보드" aria-current={active("/internal/dashboard") ? "page" : undefined} class:active={active("/internal/dashboard")} href="/internal/dashboard"><span class="nav-short" aria-hidden="true">홈</span><span class="nav-text">대시보드</span></a>
    <a aria-label="내 작업" aria-current={active("/internal/my-work") ? "page" : undefined} class:active={active("/internal/my-work")} href="/internal/my-work"><span class="nav-short" aria-hidden="true">내</span><span class="nav-text">내 작업</span></a>
    <span class="nav-label">조사</span>
    <a aria-label="신호" aria-current={active("/internal/signals") ? "page" : undefined} class:active={active("/internal/signals")} href="/internal/signals"><span class="nav-short" aria-hidden="true">신</span><span class="nav-text">신호</span></a>
    <a aria-label="사건" aria-current={active("/internal/cases") ? "page" : undefined} class:active={active("/internal/cases")} href="/internal/cases"><span class="nav-short" aria-hidden="true">사</span><span class="nav-text">사건</span></a>
    <span class="nav-label">검토·정정</span>
    <a aria-label="검토" aria-current={active("/internal/review") ? "page" : undefined} class:active={active("/internal/review")} href="/internal/review"><span class="nav-short" aria-hidden="true">검</span><span class="nav-text">검토</span></a>
    <a aria-label="정정" aria-current={active("/internal/corrections") ? "page" : undefined} class:active={active("/internal/corrections")} href="/internal/corrections"><span class="nav-short" aria-hidden="true">정</span><span class="nav-text">정정</span></a>
    <span class="nav-label">데이터</span>
    <a aria-label="출처" aria-current={active("/internal/sources") ? "page" : undefined} class:active={active("/internal/sources")} href="/internal/sources"><span class="nav-short" aria-hidden="true">출</span><span class="nav-text">출처</span></a>
    <a aria-label="규칙과 작업" aria-current={active("/internal/rules") ? "page" : undefined} class:active={active("/internal/rules")} href="/internal/rules"><span class="nav-short" aria-hidden="true">규</span><span class="nav-text">규칙·작업</span></a>
    <span class="nav-label">운영</span>
    <a aria-label="감사" aria-current={active("/internal/audit") ? "page" : undefined} class:active={active("/internal/audit")} href="/internal/audit"><span class="nav-short" aria-hidden="true">감</span><span class="nav-text">감사</span></a>
    <a aria-label="예산" aria-current={active("/internal/operations/budgets") ? "page" : undefined} class:active={active("/internal/operations/budgets")} href="/internal/operations/budgets"><span class="nav-short" aria-hidden="true">예</span><span class="nav-text">예산</span></a>
    <a aria-label="공급자" aria-current={active("/internal/operations/providers") ? "page" : undefined} class:active={active("/internal/operations/providers")} href="/internal/operations/providers"><span class="nav-short" aria-hidden="true">공</span><span class="nav-text">공급자</span></a>
    <a aria-label="작업 큐" aria-current={active("/internal/operations/jobs") ? "page" : undefined} class:active={active("/internal/operations/jobs")} href="/internal/operations/jobs"><span class="nav-short" aria-hidden="true">큐</span><span class="nav-text">작업 큐</span></a>
    <a aria-label="운영 건강" aria-current={exact("/internal/operations") ? "page" : undefined} class:active={exact("/internal/operations")} href="/internal/operations"><span class="nav-short" aria-hidden="true">건</span><span class="nav-text">운영 건강</span></a>
    <a aria-label="킬 스위치" aria-current={active("/internal/operations/kill-switches") ? "page" : undefined} class:active={active("/internal/operations/kill-switches")} href="/internal/operations/kill-switches"><span class="nav-short" aria-hidden="true">중지</span><span class="nav-text">킬 스위치</span></a>
    <span class="nav-label">접근 관리</span>
    <a aria-label="관리자" aria-current={active("/internal/admin/users") || active("/internal/admin/roles") ? "page" : undefined} class:active={active("/internal/admin/users") || active("/internal/admin/roles")} href="/internal/admin/users"><span class="nav-short" aria-hidden="true">관</span><span class="nav-text">관리자</span></a>
    <a aria-label="역할" aria-current={active("/internal/admin/roles") ? "page" : undefined} class:active={active("/internal/admin/roles")} href="/internal/admin/roles"><span class="nav-short" aria-hidden="true">역</span><span class="nav-text">역할</span></a>
    <span class="nav-label">유틸리티</span>
    <a aria-label="내부 검색" aria-current={active("/internal/search") ? "page" : undefined} class:active={active("/internal/search")} href="/internal/search"><span class="nav-short" aria-hidden="true">검색</span><span class="nav-text">내부 검색</span></a>
    <a aria-label="알림" aria-current={active("/internal/notifications") ? "page" : undefined} class:active={active("/internal/notifications")} href="/internal/notifications"><span class="nav-short" aria-hidden="true">알</span><span class="nav-text">알림</span></a>
    <a aria-label="계정" aria-current={active("/internal/account") ? "page" : undefined} class:active={active("/internal/account")} href="/internal/account"><span class="nav-short" aria-hidden="true">계</span><span class="nav-text">계정</span></a>
  </nav>
  <div class="sidebar-user"><strong>현재 세션</strong><span>{actorLabel}</span></div>
</aside>

<style>
  .sidebar {
    position: sticky;
    top: 0;
    height: 100vh;
    padding: 0.75rem 0.625rem;
    display: flex;
    flex-direction: column;
    overflow-y: auto;
    border-right: 1px solid var(--ink-700);
    background: var(--ink-950);
    color: var(--paper-0);
  }

  .sidebar nav {
    display: grid;
    gap: 0.125rem;
  }

  .sidebar nav a {
    min-height: 2.125rem;
    padding: 0.375rem 0.5rem;
    display: flex;
    align-items: center;
    gap: 0.5rem;
    border-radius: var(--radius-sm);
    color: var(--ink-300);
    font-size: 0.8125rem;
    line-height: 1.25;
    text-decoration: none;
  }

  .sidebar nav a.active {
    background: var(--ink-700);
    color: var(--paper-0);
    font-weight: 700;
  }

  .nav-short {
    display: none;
  }

  .nav-label {
    padding: 0.625rem 0.5rem 0.25rem;
    color: var(--ink-300);
    font-size: 0.75rem;
    font-weight: 700;
    line-height: 1.25;
  }

  .sidebar-user {
    margin-top: auto;
    padding: 0.75rem 0.5rem 0.25rem;
    display: grid;
    gap: 0.125rem;
    border-top: 1px solid var(--ink-700);
    color: var(--ink-300);
    font-size: 0.75rem;
  }

  .sidebar-user strong {
    color: var(--paper-0);
    font-size: 0.75rem;
  }

  @media (max-width: 820px) {
    .sidebar {
      padding-inline: 0.5rem;
    }

    .sidebar .nav-label,
    .sidebar .nav-text,
    .sidebar-user {
      display: none;
    }

    .sidebar .nav-short {
      display: inline;
    }

    .sidebar nav a {
      justify-content: center;
    }

    .sidebar nav a {
      min-height: 2.75rem;
      padding-inline: 0.375rem;
    }
  }

  @media (max-width: 620px) {
    .sidebar {
      top: 0;
      z-index: 19;
      width: 100%;
      height: auto;
      min-height: 3.5rem;
      padding: 0.375rem 0.625rem;
      flex-direction: row;
      align-items: center;
      overflow-x: auto;
      overflow-y: hidden;
      border-right: 0;
      border-bottom: 1px solid var(--ink-700);
    }

    .sidebar-user {
      display: none;
    }

    .sidebar nav {
      min-width: max-content;
      display: flex;
      align-items: center;
      gap: 0.125rem;
    }

    .sidebar nav a {
      min-width: 2.75rem;
      min-height: 2.75rem;
    }
  }
</style>
