<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="운영 상태" /><div class="operations-summary" aria-live="polite"><span class:healthy={runtime.state === "success"}>화면 상태: {runtime.state}</span><span>오류 {runtime.errors.length}건</span></div><OperationData {runtime} mode="metrics" emptyLabel="표시할 운영 상태가 없습니다." />
