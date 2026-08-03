<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import ProjectionValue from "../ProjectionValue.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, projection }: ScreenSectionProps = $props();
const knownFields = $derived(
  projection?.fields.filter((field) => field.known && field.value !== null) ??
    [],
);
</script>
<SectionHeading {section} kicker="현재 상태" />
{#if knownFields.length > 0}
  <dl class="status-revision-grid">
    {#each knownFields as field}<div><dt>{field.label}</dt><dd><ProjectionValue name={field.name} label={field.label} value={field.value} /></dd></div>{/each}
  </dl>
{:else if !projection}<p class="status-empty" role="status">상태 정보를 불러오는 중입니다.</p>
{:else}<p class="status-empty" role="status">자료 없음</p>{/if}

<style>
  .status-revision-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 19rem), 1fr));
    gap: 1px;
    margin-top: 0.5rem;
    border-block: 1px solid var(--paper-200);
    background: var(--paper-200);
  }

  .status-revision-grid > div {
    min-width: 0;
    padding: 0.375rem 0.5rem;
    background: var(--paper-0);
  }

  .status-revision-grid dt {
    display: block;
    color: var(--ink-500);
    font-size: var(--text-meta, 0.75rem);
    font-weight: 650;
    line-height: 1.4;
  }

  .status-revision-grid dd {
    display: block;
    margin: 0;
    margin-top: 0.125rem;
    font-size: var(--text-data, 0.875rem);
    font-weight: 650;
    line-height: 1.45;
    overflow-wrap: anywhere;
  }

  .status-empty {
    margin: 0.5rem 0 0;
    padding: 0.375rem 0.5rem;
    border-block: 1px solid var(--paper-200);
    color: var(--ink-700);
    font-size: var(--text-data, 0.875rem);
  }

  @media (max-width: 620px) {
    .status-revision-grid {
      grid-template-columns: minmax(0, 1fr);
    }
  }
</style>
