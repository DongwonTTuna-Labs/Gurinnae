<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, projection }: ScreenSectionProps = $props();
const branches = [
  ["신호 제외", "DISMISS", "조사 가치 없음 근거 기록 · 큐 닫기"],
  ["추가 자료 필요", "NEEDS_DATA", "확인 자료·담당자 지정 · 보류"],
  ["중복 신호로 표시", "MARK_DUPLICATE", "원본 신호 지정 · 중복 관계 보존"],
  ["사건으로 승격", "PROMOTE_TO_CASE", "사건 질문·담당자·기한 생성"],
  ["기존 사건 연결", "LINK_TO_CASE", "기존 소유 사건 연결 · 수신 확인"],
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
<SectionHeading {section} kicker="신호 분류" />
<p class="triage-warning">탐지 신호는 조사 우선순위이며 위법 또는 비리의 확정이 아닙니다.</p>
<p class="triage-instruction"><strong>분류 기록</strong><span>1개 분류 · 선택 사유 · 다음 담당자</span></p>
<div class="triage-branches" role="list" aria-label="신호 분류 결과">
  {#each branches as [label, code, explanation]}
    <article role="listitem" class:selected={code === "MARK_DUPLICATE"} data-decision={code}>
      <strong>{label}</strong><span>{explanation}</span><small>결정 코드: {code === "MARK_DUPLICATE" ? "중복 관계" : label}</small>
    </article>
  {/each}
</div>
<dl class="triage-duplicate-context" aria-label="중복 관계 확인"><div><dt>중복 대상</dt><dd>{duplicateTarget}</dd></div><div><dt>관계 유형</dt><dd>{relationship}</dd></div><div><dt>결정 사유</dt><dd>중복 근거·대상 신호 입력 후 저장</dd></div></dl>
{#if runtime.state === "conflict"}<p class="inline-state conflict" role="status">다른 분류가 먼저 저장되었습니다. 최신 신호 버전을 다시 확인하세요.</p>{/if}
{#if projection}<OperationData {runtime} {projection} mode="table" emptyLabel="현재 분류할 신호가 없습니다." />{/if}

<style>
.triage-warning,
.triage-instruction {
  margin: 0;
  font-size: 0.875rem;
  line-height: 1.5;
}

.triage-warning {
  padding: 0.625rem 0.75rem;
  border-left: 3px solid var(--amber-500);
  background: var(--amber-50);
  color: var(--ink-900);
}

.triage-instruction {
  display: flex;
  flex-wrap: wrap;
  gap: 0.25rem 0.75rem;
  padding-block: 0.5rem;
  border-bottom: 1px solid var(--paper-200);
  color: var(--ink-700);
}

.triage-instruction strong {
  color: var(--ink-900);
}

.triage-branches {
  display: grid;
  grid-template-columns: repeat(5, minmax(0, 1fr));
  margin: 0.5rem 0;
  border-top: 1px solid var(--paper-200);
}

.triage-branches article {
  display: grid;
  grid-template-columns: minmax(0, 1fr);
  align-content: start;
  gap: 0.25rem;
  min-height: 0;
  padding: 0.375rem 0.5rem;
  border: 0;
  border-right: 1px solid var(--paper-200);
  border-bottom: 1px solid var(--paper-200);
  border-left: 3px solid transparent;
  border-radius: 0;
  background: transparent;
  font-size: 0.875rem;
}

.triage-branches article:last-child {
  border-right: 0;
}

.triage-branches article.selected {
  border-left-color: var(--blue-700);
  background: var(--blue-50);
}

.triage-branches article span {
  color: var(--ink-700);
  font-size: 0.8125rem;
  line-height: 1.4;
}

.triage-branches article small {
  color: var(--ink-500);
  font-size: 0.75rem;
  line-height: 1.4;
}

.triage-duplicate-context {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  margin: 0.5rem 0;
  padding: 0;
  border: 0;
  border-block: 1px solid var(--paper-200);
  border-radius: 0;
  background: transparent;
}

.triage-duplicate-context > div {
  min-width: 0;
  padding: 0.5rem 0.625rem;
  border-right: 1px solid var(--paper-200);
}

.triage-duplicate-context > div:last-child {
  border-right: 0;
}

.triage-duplicate-context dt {
  color: var(--ink-500);
  font-size: 0.75rem;
  font-weight: 650;
}

.triage-duplicate-context dd {
  margin: 0.25rem 0 0;
  color: var(--ink-900);
  font-size: 0.875rem;
  line-height: 1.4;
  overflow-wrap: anywhere;
}

@media (max-width: 620px) {
  .triage-instruction {
    display: grid;
  }

  .triage-branches {
    grid-template-columns: minmax(0, 1fr);
  }

  .triage-branches article {
    grid-template-columns: minmax(0, 1fr) auto;
    gap: 0.25rem 0.5rem;
    border-right: 0;
  }

  .triage-branches article span {
    grid-column: 1 / -1;
  }

  .triage-duplicate-context {
    grid-template-columns: 1fr;
  }

  .triage-duplicate-context > div {
    border-right: 0;
    border-bottom: 1px solid var(--paper-200);
  }

  .triage-duplicate-context > div:last-child {
    border-bottom: 0;
  }
}
</style>
