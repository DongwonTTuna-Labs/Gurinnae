<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import { stateLabel } from "../../screen-contract";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, projection }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="운영 상태" /><div class="operations-summary" aria-live="polite"><span class:healthy={runtime.state === "success"}>화면 상태: {stateLabel(runtime.state)}</span><span>오류 {runtime.errors.length}건</span></div>{#if projection}<OperationData {runtime} {projection} mode="metrics" emptyLabel="표시할 운영 상태가 없습니다." />{/if}

<style>
  .operations-summary {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    margin: 0 0 6px;
    border-block: 1px solid var(--paper-200);
    color: var(--ink-900);
    font-size: 0.875rem;
    line-height: 1.4;
  }

  .operations-summary span {
    display: flex;
    align-items: center;
    min-height: 28px;
    padding: 4px 8px;
  }

  .operations-summary span + span {
    border-left: 1px solid var(--paper-200);
  }

  .operations-summary span:first-child::before {
    width: 7px;
    height: 7px;
    margin-right: 7px;
    border-radius: 50%;
    background: var(--blue-500);
    content: "";
    flex: 0 0 auto;
  }

  .operations-summary span.healthy::before {
    background: var(--green-500);
  }

  @media (max-width: 620px) {
    .operations-summary {
      grid-template-columns: 1fr;
    }

    .operations-summary span + span {
      border-top: 1px solid var(--paper-200);
      border-left: 0;
    }
  }

  @media (forced-colors: active) {
    .operations-summary,
    .operations-summary span + span {
      border-color: CanvasText;
    }

    .operations-summary span:first-child::before {
      background: CanvasText;
    }
  }
</style>
