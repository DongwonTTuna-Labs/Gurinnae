<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import { publicSectionNonConclusionNotice } from "../../public-status-notice";
import { buildRelatedPublicCases } from "../../related-public-cases";
import { authoritySectionStatus } from "../../screen-projection-values";
import PublicSectionStatusNotice from "../PublicSectionStatusNotice.svelte";

let { section, screen, runtime, projection }: ScreenSectionProps = $props();
const actionId = $derived(screen.id === "PUB-012" ? "open-case" : "view-case");
const cases = $derived(
  buildRelatedPublicCases(
    projection,
    runtime.navigationOptions?.[actionId] ?? [],
  ),
);
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

<div class="related-heading">
  <h2 id={`section-${section.id}-heading`}>{section.title}</h2>
</div>
<div class="related-public-cases" data-projection-state={projection?.state ?? "UNKNOWN"}>
  {#if sectionStatus}
    <p
      class:conflict={sectionStatus.tone === "conflict"}
      class:stale={sectionStatus.tone === "stale"}
      class="inline-state"
      role={sectionStatus.tone === "conflict" ? "alert" : "status"}
    >{sectionStatus.message}</p>
  {/if}
  {#if !sectionStatus?.suppressValues && cases.length > 0}
    <PublicSectionStatusNotice notice={sectionNotice} />
    <ul aria-label="관련 공개 사건 목록">
      {#each cases as item, index (item.href)}
        <li>
          {#if index === 0}
            <a id={`action-${actionId}`} href={item.href} data-action-id={actionId}>{item.title}</a>
          {:else}
            <a href={item.href}>{item.title}</a>
          {/if}
          <span class="case-status"><span class="state-dot" aria-hidden="true"></span>{item.status}</span>
        </li>
      {/each}
    </ul>
  {:else if !sectionStatus}
    <p class="empty-state" data-testid="empty-state">현재 확인 가능한 관련 공개 사건이 없습니다.</p>
  {/if}
</div>

<style>
  .related-heading {
    margin-bottom: 0.375rem;
  }

  h2 {
    margin: 0;
    font-size: var(--text-h2, 1.0625rem);
    font-weight: 650;
    line-height: 1.25;
    letter-spacing: -0.015em;
  }

  .related-public-cases {
    min-width: 0;
    border-top: 1px solid var(--paper-200);
    font-size: 0.875rem;
  }

  .inline-state,
  .empty-state {
    margin: 0;
    padding: 0.375rem 0.5rem;
    border-bottom: 1px solid var(--paper-200);
    background: var(--paper-50);
    color: var(--ink-700);
    line-height: 1.4;
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

  ul {
    margin: 0;
    padding: 0;
    list-style: none;
  }

  li {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    gap: 0.5rem;
    align-items: center;
    min-width: 0;
    padding: 0.375rem 0.5rem;
    border-bottom: 1px solid var(--paper-200);
  }

  a {
    min-width: 0;
    color: var(--blue-700);
    font-weight: 650;
    overflow-wrap: anywhere;
    text-underline-offset: 0.15em;
  }

  .case-status {
    display: inline-flex;
    gap: 0.375rem;
    align-items: center;
    color: var(--ink-700);
    font-size: 0.75rem;
    white-space: nowrap;
  }

  .state-dot {
    width: 0.4375rem;
    height: 0.4375rem;
    flex: 0 0 auto;
    border-radius: 50%;
    background: var(--blue-500);
  }

  @media (max-width: 620px) {
    li {
      grid-template-columns: minmax(0, 1fr);
      gap: 0.125rem;
    }
  }

  @media (forced-colors: active) {
    .state-dot {
      border: 1px solid CanvasText;
      background: CanvasText;
    }
  }
</style>
