<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import SectionHeading from "./SectionHeading.svelte";

let { section }: ScreenSectionProps = $props();
</script>
<article class="long-form"><SectionHeading {section} kicker="설명" /><p>표시된 기록은 출처의 범위와 시점에 따라 달라질 수 있습니다. 알려진 사실, 확인되지 않은 부분, 당사자 설명을 분리해서 읽어 주세요.</p><p><a href="/methodology">방법론과 데이터 한계 확인</a></p></article>
