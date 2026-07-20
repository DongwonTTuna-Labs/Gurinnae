<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, projection }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="현재 상태" />
<div class="status-revision-grid">
  {#if projection}
    {#each projection.fields as field}<p><span>{field.label}</span><strong>{field.value ?? "확인 필요"}</strong></p>{/each}
  {:else}<p role="status">권위 projection을 불러오는 중입니다.</p>{/if}
</div>
