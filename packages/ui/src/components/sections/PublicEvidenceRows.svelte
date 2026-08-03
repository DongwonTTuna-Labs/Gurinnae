<script lang="ts">
import type { PublicEvidenceViewModel } from "../../public-case-presentation";
import ProjectionValue from "../ProjectionValue.svelte";

let { evidence }: { evidence: readonly PublicEvidenceViewModel[] } = $props();
</script>

{#if evidence.length > 0}
  <ol class="public-evidence-rows" aria-label="공개 근거 출처">
    {#each evidence as item (item.key)}
      <li>
        {#if item.documentTitle}<div class="evidence-title"><span>문서명</span><strong>{item.documentTitle}</strong></div>{/if}
        {#if item.publisher}<div><span>출처기관</span><strong>{item.publisher}</strong></div>{/if}
        {#if item.publishedAt}<div><span>발행일</span><strong><ProjectionValue name="publishedAt" label="발행일" value={item.publishedAt} /></strong></div>{/if}
        {#if item.pageAnchor}<div><span>페이지</span><strong>{item.pageAnchor}</strong></div>{/if}
        {#if item.sourceUrl}<div class="evidence-link"><span>원문</span><a href={item.sourceUrl} target="_blank" rel="noopener noreferrer">원문 열기<span class="sr-only"> · 새 창</span></a></div>{/if}
      </li>
    {/each}
  </ol>
{:else}
  <p class="evidence-empty">공개 승인된 출처 메타데이터가 없습니다.</p>
{/if}

<style>
  .public-evidence-rows {
    display: grid;
    margin: 0;
    padding: 0;
    border-top: 1px solid var(--paper-200);
    list-style: none;
  }

  .public-evidence-rows li {
    display: grid;
    grid-template-columns: minmax(12rem, 2fr) repeat(4, minmax(7rem, 1fr));
    min-width: 0;
    border-bottom: 1px solid var(--paper-200);
  }

  .public-evidence-rows li > div {
    display: grid;
    gap: 0.125rem;
    min-width: 0;
    padding: 0.375rem 0.5rem;
    border-inline-start: 1px solid var(--paper-200);
  }

  .public-evidence-rows li > div:first-child {
    border-inline-start: 0;
  }

  .public-evidence-rows span {
    color: var(--ink-500);
    font-size: 0.75rem;
    font-weight: 650;
  }

  .public-evidence-rows strong,
  .public-evidence-rows a {
    min-width: 0;
    color: var(--ink-900);
    font-size: 0.875rem;
    line-height: 1.4;
    overflow-wrap: anywhere;
  }

  .public-evidence-rows a {
    color: var(--blue-700);
    font-weight: 650;
  }

  .evidence-empty {
    margin: 0;
    padding: 0.375rem 0.5rem;
    border-block: 1px solid var(--paper-200);
    color: var(--ink-700);
    font-size: 0.8125rem;
  }

  @media (max-width: 760px) {
    .public-evidence-rows li {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }

    .public-evidence-rows li > div:nth-child(odd) {
      border-inline-start: 0;
    }

    .public-evidence-rows .evidence-title {
      grid-column: 1 / -1;
      border-inline-start: 0;
    }
  }

  @media (max-width: 460px) {
    .public-evidence-rows li {
      grid-template-columns: minmax(0, 1fr);
    }

    .public-evidence-rows li > div {
      border-inline-start: 0;
      border-top: 1px solid var(--paper-200);
    }

    .public-evidence-rows li > div:first-child {
      border-top: 0;
    }
  }
</style>
