<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import { stateLabel } from "../../screen-contract";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, projection }: ScreenSectionProps = $props();
</script>

<SectionHeading {section} kicker="주장 검토" />
<p class="structured-state" aria-live="polite"><span class="state-dot" aria-hidden="true"></span><span>현재 상태</span><strong>{stateLabel(runtime.state)}</strong></p>
{#if projection}<OperationData {runtime} {projection} mode="cards" emptyLabel="검토할 주장이 없습니다." />{/if}

<style>
  .structured-state {
    position: absolute;
    width: 1px;
    height: 1px;
    padding: 0;
    margin: -1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
    white-space: nowrap;
    border: 0;
  }

  .structured-state span {
    font-size: 0.75rem;
    font-weight: 650;
  }

  .state-dot {
    width: 7px;
    height: 7px;
    flex: 0 0 auto;
    border-radius: 50%;
    background: var(--blue-500);
  }
</style>
