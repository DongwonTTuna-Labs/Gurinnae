<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import { stateLabel } from "../../screen-contract";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, projection }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="주장 검토" /><p>{section.purpose}</p><p class="structured-state" aria-live="polite">현재 상태: {stateLabel(runtime.state)} · 각 주장은 근거·반대 근거·검증 상태를 분리해 확인합니다.</p>{#if projection}<OperationData {runtime} {projection} mode="cards" emptyLabel="검토할 주장이 없습니다." />{/if}
