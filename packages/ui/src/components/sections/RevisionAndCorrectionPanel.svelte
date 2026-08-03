<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, projection }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="정정과 철회" /><p class="correction-principle">정정 전 내용과 정정 사유, 적용 시각을 보존하며 이전 공개 기록을 조용히 덮어쓰지 않습니다.</p>{#if projection}<OperationData {runtime} {projection} mode="timeline" emptyLabel="표시할 정정·철회 기록이 없습니다." />{/if}

<style>
  .correction-principle {
    margin: 0 0 0.625rem;
    padding: 0.375rem 0.625rem;
    border-left: 2px solid var(--amber-500);
    background: var(--amber-50);
    color: var(--amber-900);
    font-size: 0.8125rem;
    line-height: 1.4;
  }

  @media (forced-colors: active) {
    .correction-principle {
      border-color: CanvasText;
      background: Canvas;
      color: CanvasText;
    }
  }
</style>
