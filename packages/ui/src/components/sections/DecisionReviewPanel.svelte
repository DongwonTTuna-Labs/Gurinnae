<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="독립 검토" /><div class="decision-gate" role="note"><strong>사람의 승인 필요</strong><p>현재 snapshot, 미해결 blocker, 독립성, step-up 상태가 모두 충족되어야 결정할 수 있습니다.</p></div><OperationData {runtime} mode="cards" emptyLabel="결정할 검토 snapshot이 없습니다." />
