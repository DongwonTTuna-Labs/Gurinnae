<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, projection }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="변경 이력" />{#if projection}<OperationData {runtime} {projection} mode="timeline" emptyLabel="기록된 개정 이력이 없습니다." />{/if}
