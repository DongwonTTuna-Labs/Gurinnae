<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="신호 분류" /><p>탐지 신호는 조사 우선순위이며 위법 또는 비리의 확정이 아닙니다.</p><OperationData {runtime} mode="table" emptyLabel="현재 분류할 신호가 없습니다." />
