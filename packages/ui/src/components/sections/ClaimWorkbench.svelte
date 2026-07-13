<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="주장 검토" /><p>각 주장은 근거, 반대 근거, 검증 상태와 분리해 편집합니다.</p><OperationData {runtime} mode="cards" emptyLabel="검토할 주장이 없습니다." />
