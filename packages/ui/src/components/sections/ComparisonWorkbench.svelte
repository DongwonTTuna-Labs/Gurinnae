<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, projection }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="비교" /><p class="comparison-note">동일 단위와 기간인지 확인한 뒤 비교하며, 순위나 단정으로 해석하지 않습니다.</p>{#if projection}<OperationData {runtime} {projection} mode="table" emptyLabel="비교할 수 있는 동질 record가 없습니다." />{/if}
