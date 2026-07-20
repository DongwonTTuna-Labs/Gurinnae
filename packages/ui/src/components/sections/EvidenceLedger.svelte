<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, projection }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="근거 원장" /><p class="evidence-note">근거 ID, locator, 검증 상태와 갱신 시점을 함께 확인합니다. 보호 필드는 브라우저에 원문으로 표시하지 않습니다.</p>{#if projection}<OperationData {runtime} {projection} mode="cards" emptyLabel="현재 범위에 연결된 검증 근거가 없습니다." />{/if}
