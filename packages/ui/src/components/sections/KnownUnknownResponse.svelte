<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, projection }: ScreenSectionProps = $props();
const showResponse = $derived(/response|party/i.test(section.id));
</script>

<SectionHeading {section} kicker="자료 구분" />
<div class="known-unknown-response">
  <article>
    <h3>확인된 내용</h3>
    {#if projection}
      <dl>{#each projection.fields.filter((field) => field.known) as field}<div><dt>{field.label}</dt><dd>{field.value}</dd></div>{/each}</dl>
    {:else}
      <p>권위 projection을 불러오는 중입니다.</p>
    {/if}
  </article>
  <article>
    <h3>아직 모르는 내용</h3>
    {#if projection && projection.fields.some((field) => !field.known)}
      <dl>{#each projection.fields.filter((field) => !field.known) as field}<div><dt>{field.label}</dt><dd>확인 필요</dd></div>{/each}</dl>
    {:else}
      <p>의도와 책임은 자동으로 추정하지 않습니다.</p>
    {/if}
  </article>
  {#if showResponse}
    <article>
      <h3>당사자 설명</h3>
      <dl><div><dt>접수 자료</dt><dd>원 주장과 구분 · 동일 중요도 검토</dd></div></dl>
    </article>
  {/if}
</div>

<style>
  .known-unknown-response {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 19rem), 1fr));
    border-block: 1px solid var(--paper-200);
  }

  article {
    min-width: 0;
    padding: 0.375rem 0.5rem;
    border-inline-start: 1px solid var(--paper-200);
  }

  article:first-child {
    border-inline-start: 0;
  }

  h3 {
    margin: 0 0 0.25rem;
    color: var(--ink-900);
    font-size: 1rem;
    font-weight: 650;
    line-height: 1.35;
  }

  dl,
  p {
    margin: 0;
  }

  dl > div {
    display: grid;
    grid-template-columns: minmax(6rem, 38%) minmax(0, 1fr);
    gap: 0.5rem;
    align-items: baseline;
    padding: 0.375rem 0;
    border-top: 1px solid var(--paper-200);
  }

  dl > div:first-child {
    border-top: 0;
  }

  dt {
    color: var(--ink-500);
    font-size: 0.75rem;
    font-weight: 650;
  }

  dd {
    min-width: 0;
    margin: 0;
    color: var(--ink-900);
    font-size: 0.875rem;
    line-height: 1.45;
    overflow-wrap: anywhere;
  }

  p {
    color: var(--ink-700);
    font-size: 0.8125rem;
    line-height: 1.4;
  }

  @media (max-width: 620px) {
    .known-unknown-response {
      grid-template-columns: 1fr;
    }

    article,
    article:first-child {
      border-top: 1px solid var(--paper-200);
      border-inline-start: 0;
    }

    article:first-child {
      border-top: 0;
    }

    dl > div {
      grid-template-columns: minmax(0, 1fr);
      gap: 0.125rem;
    }
  }
</style>
