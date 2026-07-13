<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import SectionHeading from "./SectionHeading.svelte";

let { section, screen }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="안내" />
<div class="structured-content"><p>이 영역은 {screen.title}에서 확인해야 할 기준과 한계를 설명합니다.</p><p>자동 분석은 사실 확정이 아니며, 공개 전 근거와 반론을 독립적으로 검토합니다.</p></div>
