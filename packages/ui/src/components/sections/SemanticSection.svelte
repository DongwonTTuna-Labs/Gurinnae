<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import { stateLabel, typedScreenViewModel } from "../../screen-contract";
import SectionHeading from "./SectionHeading.svelte";

let { section, screen, runtime, projection }: ScreenSectionProps = $props();
const contract = $derived(typedScreenViewModel(screen));
const typedSection = $derived(
  contract.sections.find((item) => item.id === section.id),
);
</script>

<SectionHeading {section} kicker={typedSection?.region === "next-action" ? "다음 단계" : "확인할 내용"} />
<div class="semantic-section" data-region={typedSection?.region ?? "state"}>
  <p>{section.purpose}</p>
  <div class="semantic-section-state"><span>현재 상태</span><strong>{stateLabel(runtime.state)}</strong></div>
  {#if runtime.state === "loading" || runtime.state === "initial-loading"}<p role="status">서버가 확인한 내용을 불러오는 중입니다.</p>
  {:else if runtime.state === "empty" || runtime.state === "filtered-empty"}<p role="status">이 범위에 확인된 기록이 없습니다. 검색 조건과 기준 시각을 확인하세요.</p>
  {:else if runtime.state === "error" || runtime.state === "server-error"}<p role="alert">이 영역을 확인하지 못했습니다. 저장된 상태를 보존한 채 안전하게 다시 시도하세요.</p>
  {:else if runtime.state === "forbidden" || runtime.state === "unauthorized"}<p role="alert">현재 권한으로는 이 영역을 열 수 없습니다. 권한 담당자에게 요청하세요.</p>
  {:else if runtime.state === "offline"}<p role="status">네트워크가 끊겼습니다. 입력과 마지막 서버 확인 상태를 보존합니다.</p>
  {:else if runtime.state === "conflict"}<p role="alert">다른 변경이 먼저 저장되었습니다. 최신 버전을 다시 확인한 뒤 이어가세요.</p>
  {:else if runtime.state === "stale" || runtime.state === "superseded"}<p role="status">표시된 자료가 최신이 아닙니다. 기준 시각을 확인하고 읽기 전용으로 갱신하세요.</p>
  {:else if runtime.state === "maintenance"}<p role="status">서비스 점검 중입니다. 안전한 읽기 작업만 유지됩니다.</p>
  {:else if projection && projection.fields.length > 0}<dl class="structured-fields">{#each projection.fields as field}<div><dt>{field.label}</dt><dd>{field.value ?? "확인 필요"}</dd></div>{/each}</dl>
  {:else}<p role="status">이 영역에 표시할 권위 projection이 없습니다.</p>{/if}
</div>
