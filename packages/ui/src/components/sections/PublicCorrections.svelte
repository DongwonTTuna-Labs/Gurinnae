<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import { buildHomeCorrections } from "../../public-corrections";
import { publicSectionNonConclusionNotice } from "../../public-status-notice";
import { authoritySectionStatus } from "../../screen-projection-values";
import PublicSectionStatusNotice from "../PublicSectionStatusNotice.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, projection }: ScreenSectionProps = $props();
const corrections = $derived(buildHomeCorrections(projection));
const sectionNotice = publicSectionNonConclusionNotice();
const sectionStatus = $derived(
  authoritySectionStatus({
    projectionPresent: projection !== undefined,
    runtimeState: runtime.state,
    declaredFieldCount: projection?.fields.length ?? 0,
    knownFieldCount:
      projection?.fields.filter((field) => field.known).length ?? 0,
    ...(projection
      ? {
          projectionState: projection.state,
          errorMessage: projection.errorMessage,
        }
      : {}),
  }),
);
</script>

<SectionHeading {section} kicker="정정 기록" />
<div class="public-corrections" data-projection-state={projection?.state ?? "UNKNOWN"}>
  {#if sectionStatus}
    <p
      class:conflict={sectionStatus.tone === "conflict"}
      class:stale={sectionStatus.tone === "stale"}
      class="inline-state"
      role={sectionStatus.tone === "conflict" ? "alert" : "status"}
    >{sectionStatus.message}</p>
  {/if}
  {#if !sectionStatus?.suppressValues && corrections.length > 0}
    <PublicSectionStatusNotice notice={sectionNotice} />
    <ul aria-label="최근 설명·정정·철회 목록">
      {#each corrections as item (item.key)}
        <li class="projection-record">
          <div class="correction-heading">
            <a href={item.href}>{item.summary}</a>
            <span class="correction-status"><span class="state-dot" aria-hidden="true"></span>{item.status}</span>
          </div>
          <p>{item.reason}</p>
          <p class="correction-date">게시일 {item.publishedAt}</p>
        </li>
      {/each}
    </ul>
  {:else if !sectionStatus}
    <p class="empty-state" data-testid="empty-state">현재 확인 가능한 설명·정정·철회 기록이 없습니다.</p>
  {/if}
</div>

<style>
  .public-corrections {
    min-width: 0;
    border-top: 1px solid var(--paper-200);
    font-size: 0.875rem;
  }

  ul {
    margin: 0;
    padding: 0;
    list-style: none;
  }

  li {
    min-width: 0;
    padding: 0.375rem 0.5rem;
    border-bottom: 1px solid var(--paper-200);
  }

  .correction-heading {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    gap: 0.5rem;
    align-items: center;
  }

  a {
    color: var(--blue-700);
    font-weight: 650;
    overflow-wrap: anywhere;
    text-underline-offset: 0.15em;
  }

  .correction-status {
    display: inline-flex;
    gap: 0.375rem;
    align-items: center;
    color: var(--ink-700);
    font-size: 0.75rem;
    white-space: nowrap;
  }

  .state-dot {
    width: 0.45rem;
    height: 0.45rem;
    border-radius: 999px;
    background: var(--blue-600);
  }

  li > p,
  .inline-state,
  .empty-state {
    margin: 0.25rem 0 0;
    color: var(--ink-700);
    line-height: 1.4;
  }

  .correction-date {
    color: var(--ink-500);
    font-size: 0.75rem;
  }

  .inline-state,
  .empty-state {
    margin: 0;
    padding: 0.375rem 0.5rem;
    border-bottom: 1px solid var(--paper-200);
    background: var(--paper-50);
  }

  .inline-state.conflict {
    border-color: var(--red-500);
    background: var(--red-50);
    color: var(--red-900);
  }

  .inline-state.stale {
    border-color: var(--amber-500);
    background: var(--amber-50);
    color: var(--amber-900);
  }
</style>
