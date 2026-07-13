<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="균형 잡힌 설명" />
<div class="known-unknown-response"><article><h3>확인된 내용</h3><p>{runtime.state === "success" ? "검증된 계약 응답에 포함된 내용만 표시합니다." : "현재 확인 가능한 기록이 제한적입니다."}</p></article><article><h3>아직 모르는 내용</h3><p>원자료 범위 밖의 의도와 책임은 자동으로 추정하지 않습니다.</p></article><article><h3>당사자 설명</h3><p>접수된 설명과 답변은 원 주장과 구분해 같은 중요도로 검토합니다.</p></article></div>
