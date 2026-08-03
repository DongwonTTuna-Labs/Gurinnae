<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, projection }: ScreenSectionProps = $props();
</script>

<SectionHeading {section} kicker="비교" />
<dl class="comparison-criteria" aria-label="비교 기준과 해석 제한">
  <div><dt>비교 기준</dt><dd>동일 단위 · 동일 기간 확인 후 비교</dd></div>
  <div><dt>해석 제한</dt><dd>순위·단정의 근거로 사용하지 않음</dd></div>
</dl>
{#if projection}<OperationData {runtime} {projection} mode="table" emptyLabel="비교할 수 있는 동질 기록이 없습니다." />{/if}

<style>
  .comparison-criteria {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    margin: 0 0 10px;
    border-block: 1px solid var(--paper-200);
  }

  .comparison-criteria > div {
    min-width: 0;
    padding: 8px 11px;
    border-inline-start: 1px solid var(--paper-200);
  }

  .comparison-criteria > div:first-child {
    border-inline-start: 0;
  }

  dt {
    color: var(--ink-500);
    font-size: 0.75rem;
    font-weight: 650;
  }

  dd {
    margin: 3px 0 0;
    color: var(--ink-900);
    font-size: 0.8125rem;
    line-height: 1.45;
  }

  @media (max-width: 620px) {
    .comparison-criteria {
      grid-template-columns: 1fr;
    }

    .comparison-criteria > div,
    .comparison-criteria > div:first-child {
      border-top: 1px solid var(--paper-200);
      border-inline-start: 0;
    }

    .comparison-criteria > div:first-child {
      border-top: 0;
    }
  }
</style>
