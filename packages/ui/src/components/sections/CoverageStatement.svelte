<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import { stateTone } from "../../screen-chrome";
import { stateLabel } from "../../screen-contract";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, screen, projection }: ScreenSectionProps = $props();
const knownFields = $derived(
  projection?.fields.filter((field) => field.known).length ?? 0,
);
const tone = $derived(stateTone(runtime.state));
</script>

<SectionHeading {section} kicker="범위와 최신성" />
<div class="coverage-statement">
  <dl class="coverage-stats" aria-label="화면 범위">
    <div>
      <dt>연결 자료</dt>
      <dd><strong>{screen.dataOperations.length}</strong><span>개</span></dd>
    </div>
    <div>
      <dt>확인 항목</dt>
      <dd><strong>{knownFields}</strong><span>개</span></dd>
    </div>
    <div>
      <dt>현재 상태</dt>
      <dd class="state-value"><span class={`state-dot ${tone}`} aria-hidden="true"></span><strong>{stateLabel(runtime.state)}</strong></dd>
    </div>
  </dl>
  <p class="coverage-note">지연·누락·비공개 범위는 결과와 별도로 표시합니다.</p>
</div>

<style>
  .coverage-statement {
    border-block: 1px solid var(--paper-200);
  }

  .coverage-stats {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    margin: 0;
  }

  .coverage-stats > div {
    min-width: 0;
    padding: 0.375rem 0.5rem;
    border-inline-start: 1px solid var(--paper-200);
  }

  .coverage-stats > div:first-child {
    border-inline-start: 0;
  }

  dt {
    color: var(--ink-500);
    font-size: 0.75rem;
    font-weight: 650;
  }

  dd {
    display: flex;
    align-items: baseline;
    gap: 4px;
    margin: 2px 0 0;
    overflow-wrap: anywhere;
  }

  dd strong {
    font-size: 1.25rem;
    line-height: 1.2;
  }

  dd span:not(.state-dot) {
    color: var(--ink-500);
    font-size: 0.75rem;
  }

  .state-value {
    align-items: center;
  }

  .state-value strong {
    font-size: 0.9375rem;
  }

  .state-dot {
    width: 7px;
    height: 7px;
    flex: 0 0 auto;
    border-radius: 50%;
    background: var(--ink-500);
  }

  .state-dot.info {
    background: var(--blue-500);
  }

  .state-dot.status {
    background: var(--green-500);
  }

  .state-dot.caution {
    background: var(--amber-500);
  }

  .state-dot.status-alert {
    background: var(--red-500);
  }

  .coverage-note {
    margin: 0;
    padding: 0.375rem 0.5rem;
    border-top: 1px solid var(--paper-200);
    color: var(--ink-700);
    font-size: 0.8125rem;
    line-height: 1.45;
  }

  @media (max-width: 620px) {
    .coverage-stats {
      grid-template-columns: 1fr;
    }

    .coverage-stats > div,
    .coverage-stats > div:first-child {
      padding: 0.375rem 0.5rem;
      border-top: 1px solid var(--paper-200);
      border-inline-start: 0;
    }

    .coverage-stats > div:first-child {
      border-top: 0;
    }

    .coverage-note {
      padding-inline: 0.5rem;
    }
  }
</style>
