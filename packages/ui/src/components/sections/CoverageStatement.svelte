<script lang="ts">
import { semanticRecords } from "../../data";
import type { ScreenSectionProps } from "../../index";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, screen }: ScreenSectionProps = $props();
const count = $derived(semanticRecords(runtime).length);
</script>
<SectionHeading {section} kicker="범위와 최신성" />
<div class="coverage-statement"><p><strong>{screen.dataOperations.length}</strong>개 연결 자료의 범위를 확인합니다.</p><p>현재 응답에서 <strong>{count}</strong>개 항목을 확인했습니다.</p><p>지연·누락·비공개 범위는 결과와 별도로 표시합니다.</p></div>
