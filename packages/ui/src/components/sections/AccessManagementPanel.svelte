<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, projection }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="접근 관리" /><div class="access-warning" role="note"><strong>최소 권한</strong><p>역할 변경은 사유, 만료, step-up 및 감사 기록을 요구합니다.</p></div>{#if projection}<OperationData {runtime} {projection} mode="table" emptyLabel="표시할 사용자 또는 역할이 없습니다." />{/if}
