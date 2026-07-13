<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="변경 이력" /><OperationData {runtime} mode="timeline" emptyLabel="기록된 리비전 이력이 없습니다." />
