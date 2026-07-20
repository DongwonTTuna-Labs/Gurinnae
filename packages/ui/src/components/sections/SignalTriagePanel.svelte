<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, projection }: ScreenSectionProps = $props();
const branches = [
  ["신호 제외", "DISMISS", "조사 가치가 없다는 근거를 남기고 큐에서 닫습니다."],
  [
    "추가 자료 필요",
    "NEEDS_DATA",
    "확인할 자료와 담당자를 지정한 뒤 보류합니다.",
  ],
  [
    "중복 신호로 표시",
    "MARK_DUPLICATE",
    "원본 신호를 지정하고 중복 관계를 보존합니다.",
  ],
  [
    "사건으로 승격",
    "PROMOTE_TO_CASE",
    "사건 질문·담당자·기한을 함께 생성합니다.",
  ],
  [
    "기존 사건 연결",
    "LINK_TO_CASE",
    "이미 소유된 사건으로 연결하고 수신을 확인합니다.",
  ],
] as const;
const duplicateTarget = $derived(
  projection?.fields.find((field) =>
    /duplicate|target|related/iu.test(field.name),
  )?.value ?? "확인 필요",
);
const relationship = $derived(
  projection?.fields.find((field) => /relationship|relation/iu.test(field.name))
    ?.value ?? "확인 필요",
);
</script>
<SectionHeading {section} kicker="신호 분류" /><p>탐지 신호는 조사 우선순위이며 위법 또는 비리의 확정이 아닙니다. 아래 다섯 갈래 중 정확히 하나를 선택하고, 선택 이유와 다음 담당자를 기록합니다.</p>
<div class="triage-branches" role="list" aria-label="신호 분류 결과">
  {#each branches as [label, code, explanation]}
    <article role="listitem" class:selected={code === "MARK_DUPLICATE"} data-decision={code}>
      <strong>{label}</strong><span>{explanation}</span><small>결정 코드: {code === "MARK_DUPLICATE" ? "중복 관계" : label}</small>
    </article>
  {/each}
</div>
<dl class="triage-duplicate-context" aria-label="중복 관계 확인"><div><dt>중복 대상</dt><dd>{duplicateTarget}</dd></div><div><dt>관계 유형</dt><dd>{relationship}</dd></div><div><dt>결정 사유</dt><dd>중복 근거와 대상 신호를 함께 입력해야 저장됩니다.</dd></div></dl>
{#if runtime.state === "conflict"}<p class="inline-state conflict" role="alert">다른 분류가 먼저 저장되었습니다. 최신 신호 버전을 다시 확인하세요.</p>{/if}
{#if projection}<OperationData {runtime} {projection} mode="table" emptyLabel="현재 분류할 신호가 없습니다." />{/if}
