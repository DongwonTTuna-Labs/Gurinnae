<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime }: ScreenSectionProps = $props();
const fieldCount = $derived(
  Object.values(runtime.forms).reduce((sum, fields) => sum + fields.length, 0),
);
</script>
<SectionHeading {section} kicker="단계별 입력" /><div class="guided-form-intro"><p>필수 입력, 검토, 제출 순서로 진행합니다. 세션과 권한은 각 단계에서 서버가 다시 확인합니다.</p><p>현재 계약에서 <strong>{fieldCount}</strong>개 입력 필드를 준비했습니다.</p></div>
