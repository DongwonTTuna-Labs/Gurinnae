<script lang="ts">
  import type { ScreenSectionProps } from "../../index";
  import { stateLabel, typedScreenViewModel } from "../../screen-contract";
  import SectionHeading from "./SectionHeading.svelte";

  let { section, screen, runtime }: ScreenSectionProps = $props();
  const contract = $derived(typedScreenViewModel(screen));
  const typedSection = $derived(contract.sections.find((item) => item.id === section.id));
</script>

<SectionHeading {section} kicker={typedSection?.region === "next-action" ? "다음 단계" : "확인할 내용"} />
<div class="semantic-section" data-region={typedSection?.region ?? "state"}>
  <p>{section.purpose}</p>
  <div class="semantic-section-state"><span>현재 상태</span><strong>{stateLabel(runtime.state)}</strong></div>
  {#if runtime.state === "loading"}<p role="status">서버가 확인한 내용을 불러오는 중입니다.</p>
  {:else if runtime.state === "empty"}<p role="status">이 범위에 확인할 기록이 아직 없습니다.</p>
  {:else if runtime.state === "error"}<p role="alert">이 영역을 확인하지 못했습니다. 오류 내용을 확인한 뒤 안전하게 다시 시도하세요.</p>
  {:else if runtime.state === "forbidden"}<p role="alert">현재 권한으로는 이 영역을 열 수 없습니다.</p>{/if}
</div>
