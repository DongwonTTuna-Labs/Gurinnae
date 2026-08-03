<script lang="ts">
import { onMount } from "svelte";
import type { ScreenRuntime, ScreenViewModel } from "../../index";
import { caseTaskLinksForPath } from "../../screen-chrome";

let { screen, runtime }: { screen: ScreenViewModel; runtime: ScreenRuntime } =
  $props();
const caseTaskLinks = $derived(caseTaskLinksForPath(runtime.pathname ?? ""));
let activeSection = $state("");
$effect(() => {
  const firstSection = screen.sections[0]?.id ?? "";
  if (
    !activeSection ||
    !screen.sections.some((section) => section.id === activeSection)
  ) {
    activeSection = firstSection;
  }
});
onMount(() => {
  const reconcileHash = () => {
    const hash = window.location.hash.replace(/^#/, "");
    if (hash && screen.sections.some((section) => section.id === hash)) {
      activeSection = hash;
    }
  };
  reconcileHash();
  window.addEventListener("hashchange", reconcileHash);
  return () => window.removeEventListener("hashchange", reconcileHash);
});
</script>

<nav class="task-rail" aria-label="현재 화면 영역">{#each screen.sections as section, index}<a class:active={activeSection === section.id} href={`#${section.id}`} onclick={() => activeSection = section.id}><span>{section.title}</span><span class="task-count">{index + 1}</span></a>{/each}{#if caseTaskLinks.length > 0}<div class="task-rail-siblings" aria-label="케이스 작업 이동"><span>케이스 작업</span>{#each caseTaskLinks as link}<a href={link.href} class:active={runtime.pathname === link.href}>{link.label}</a>{/each}</div>{/if}</nav>
<label class="compact-task-selector" for={`compact-task-${screen.id.toLowerCase()}`}>화면 영역<select id={`compact-task-${screen.id.toLowerCase()}`} value={activeSection} onchange={(event) => { const value = (event.currentTarget as HTMLSelectElement).value; if (value) window.location.hash = value; }}>{#each screen.sections as section}<option value={section.id}>{section.title}</option>{/each}</select></label>

<style>
  .task-rail {
    position: sticky;
    top: 3.75rem;
    padding: 0.375rem;
    display: grid;
    gap: 0.125rem;
    border: 1px solid var(--paper-200);
    border-radius: var(--radius-sm);
    background: var(--paper-0);
  }

  .task-rail a {
    min-height: 2.25rem;
    padding: 0.375rem 0.5rem;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.5rem;
    border-radius: var(--radius-sm);
    color: var(--ink-700);
    font-size: 0.8125rem;
    line-height: 1.25;
    text-decoration: none;
  }

  .task-rail a.active {
    background: var(--blue-50);
    color: var(--blue-900);
    font-weight: 700;
  }

  .task-count {
    min-width: 1.25rem;
    color: var(--ink-500);
    font-size: 0.75rem;
    text-align: right;
  }

  .task-rail-siblings {
    margin-top: 0.375rem;
    padding-top: 0.375rem;
    border-top: 1px solid var(--paper-200);
  }

  .task-rail-siblings > span {
    display: block;
    padding: 0.25rem 0.5rem;
    color: var(--ink-500);
    font-size: 0.75rem;
    font-weight: 700;
  }

  .task-rail-siblings a {
    min-height: 2.25rem;
    font-size: 0.75rem;
  }

  .compact-task-selector {
    display: none;
  }

  @media (max-width: 820px) {
    .task-rail {
      position: static;
      display: flex;
      overflow-x: auto;
    }

    .task-rail > a {
      min-width: max-content;
      min-height: 2.75rem;
    }

    .task-rail-siblings {
      margin: 0 0 0 0.375rem;
      padding: 0 0 0 0.375rem;
      display: flex;
      align-items: center;
      border-top: 0;
      border-left: 1px solid var(--paper-200);
    }

    .task-rail-siblings > span,
    .task-rail-siblings a {
      min-width: max-content;
    }

    .task-rail-siblings a {
      min-height: 2.75rem;
    }
  }

  @media (max-width: 620px) {
    .task-rail {
      display: none;
    }

    .compact-task-selector {
      width: 100%;
      padding: 0.625rem 0.75rem;
      display: grid;
      gap: 0.375rem;
      border: 1px solid var(--paper-200);
      border-radius: var(--radius-sm);
      background: var(--paper-0);
      color: var(--ink-700);
      font-size: 0.75rem;
      font-weight: 700;
    }

    .compact-task-selector select {
      width: 100%;
      min-height: 2.75rem;
    }
  }
</style>
