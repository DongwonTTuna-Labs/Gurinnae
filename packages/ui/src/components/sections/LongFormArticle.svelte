<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import SectionHeading from "./SectionHeading.svelte";

let { section }: ScreenSectionProps = $props();
</script>

<article class="long-form">
  <SectionHeading {section} kicker="자료 구분" />
  <p class="article-limit">기록은 출처의 범위와 시점에 따라 달라질 수 있습니다.</p>
  <dl class="article-legend">
    <div><dt>확인 사실</dt><dd>출처로 확인된 범위</dd></div>
    <div><dt>중요한 미확인</dt><dd>원자료에서 확인되지 않은 범위</dd></div>
    <div><dt>당사자 설명</dt><dd>관측 사실과 구분된 제출 내용</dd></div>
  </dl>
  <p class="methodology-link"><a href="/methodology">방법론과 데이터 한계 확인</a></p>
</article>

<style>
  .long-form {
    display: grid;
    gap: 10px;
    max-width: 72ch;
  }

  p,
  dl {
    margin: 0;
  }

  .article-limit {
    color: var(--ink-700);
    font-size: 0.9375rem;
    line-height: 1.5;
  }

  .article-legend {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    border-block: 1px solid var(--paper-200);
  }

  .article-legend > div {
    min-width: 0;
    padding: 9px 11px;
    border-inline-start: 1px solid var(--paper-200);
  }

  .article-legend > div:first-child {
    border-inline-start: 0;
  }

  dt {
    color: var(--ink-500);
    font-size: 0.75rem;
    font-weight: 650;
  }

  dd {
    margin: 4px 0 0;
    color: var(--ink-900);
    font-size: 0.8125rem;
    line-height: 1.45;
  }

  .methodology-link {
    font-size: 0.8125rem;
  }

  @media (max-width: 620px) {
    .article-legend {
      grid-template-columns: 1fr;
    }

    .article-legend > div,
    .article-legend > div:first-child {
      border-top: 1px solid var(--paper-200);
      border-inline-start: 0;
    }

    .article-legend > div:first-child {
      border-top: 0;
    }
  }
</style>
