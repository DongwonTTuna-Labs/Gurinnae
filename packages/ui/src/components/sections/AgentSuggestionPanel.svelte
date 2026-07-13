<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="AI 제안" /><p class="agent-warning">제안은 자동 적용되지 않습니다. citation과 abstention reason을 확인한 뒤 사람이 수락하거나 거절합니다.</p><OperationData {runtime} mode="cards" emptyLabel="대기 중인 agent 제안이 없습니다." />
