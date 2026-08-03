<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, projection }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="현재 상태" />
<div class="status-revision-grid">
  {#if projection}
    {#each projection.fields as field}<p><span>{field.label}</span><strong>{field.value ?? "확인 필요"}</strong></p>{/each}
  {:else}<p role="status">권위 projection을 불러오는 중입니다.</p>{/if}
</div>

<style>
  .status-revision-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 19rem), 1fr));
    gap: 1px;
    margin-top: 0.5rem;
    border-block: 1px solid var(--paper-200);
    background: var(--paper-200);
  }

  .status-revision-grid p {
    min-width: 0;
    margin: 0;
    padding: 0.375rem 0.5rem;
    background: var(--paper-0);
  }

  .status-revision-grid span {
    display: block;
    color: var(--ink-500);
    font-size: var(--text-meta, 0.75rem);
    font-weight: 650;
    line-height: 1.4;
  }

  .status-revision-grid strong {
    display: block;
    margin-top: 0.125rem;
    font-size: var(--text-data, 0.875rem);
    font-weight: 650;
    line-height: 1.45;
    overflow-wrap: anywhere;
  }

  @media (max-width: 620px) {
    .status-revision-grid {
      grid-template-columns: minmax(0, 1fr);
    }
  }
</style>
