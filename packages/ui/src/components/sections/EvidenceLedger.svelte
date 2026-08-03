<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, projection }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="근거 원장" /><p class="evidence-note">보호 필드는 브라우저에 원문으로 표시하지 않습니다.</p>{#if projection}<OperationData {runtime} {projection} mode="cards" emptyLabel="현재 범위에 연결된 검증 근거가 없습니다." />{/if}

<style>
  .evidence-note {
    margin: 0 0 0.625rem;
    padding: 0.375rem 0.625rem;
    border-left: 2px solid var(--amber-500);
    background: var(--amber-50);
    color: var(--amber-900);
    font-size: 0.8125rem;
    line-height: 1.4;
  }

  @media (forced-colors: active) {
    .evidence-note {
      border-color: CanvasText;
      background: Canvas;
      color: CanvasText;
    }
  }
</style>
