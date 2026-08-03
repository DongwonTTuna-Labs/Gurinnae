<script lang="ts">
import type {
  ScreenRuntime,
  ScreenViewModel,
  TypedScreenViewModel,
} from "../../index";
import { contextBlockerMessage, stateTone } from "../../screen-chrome";
import { stateLabel } from "../../screen-contract";

let {
  screen,
  runtime,
  contract,
}: {
  screen: ScreenViewModel;
  runtime: ScreenRuntime;
  contract: TypedScreenViewModel;
} = $props();
const tone = $derived(stateTone(runtime.state));
const guidance = $derived(
  contextBlockerMessage(runtime.state, runtime.errors.length),
);
</script>

<aside class="context-rail" aria-label="작업 맥락">
  <section class="context-section">
    <h2>결정 전 확인</h2>
    <dl class="context-facts">
      <div class="context-fact">
        <dt>상태</dt>
        <dd><span class={`context-state ${tone}`}><span class="status-dot" aria-hidden="true"></span>{stateLabel(runtime.state)}</span></dd>
      </div>
    </dl>
    <p class="context-guidance">{guidance}</p>
  </section>
  <section class="context-section">
    <h2>현재 조건</h2>
    <dl class="context-facts">
      <div class="context-fact"><dt>오류</dt><dd>{runtime.errors.length}건</dd></div>
      <div class="context-fact"><dt>세션</dt><dd>{runtime.sessionExpiresAt ?? "확인 필요"}</dd></div>
    </dl>
  </section>
  <section class="context-section">
    <h2>연결 자료</h2>
    <dl class="context-facts">
      <div class="context-fact"><dt>자료</dt><dd>{screen.dataOperations.length}개</dd></div>
      <div class="context-fact"><dt>다음 행동</dt><dd>{contract.primaryActionLabel ?? "확인 필요"}</dd></div>
    </dl>
  </section>
</aside>

<style>
  .context-rail {
    position: sticky;
    top: 3.75rem;
    overflow: hidden;
    border: 1px solid var(--paper-200);
    border-radius: var(--radius-sm);
    background: var(--paper-0);
  }

  .context-section {
    padding: 0.75rem;
    border-bottom: 1px solid var(--paper-200);
  }

  .context-section:last-child {
    border-bottom: 0;
  }

  .context-section h2 {
    margin: 0 0 0.5rem;
    color: var(--ink-900);
    font-size: 1rem;
    font-weight: 650;
  }

  .context-facts {
    margin: 0;
  }

  .context-fact {
    padding: 0.375rem 0;
    display: grid;
    grid-template-columns: 4.75rem minmax(0, 1fr);
    gap: 0.5rem;
    border-top: 1px solid var(--paper-200);
  }

  .context-fact dt,
  .context-fact dd {
    margin: 0;
    font-size: 0.8125rem;
    line-height: 1.4;
  }

  .context-fact dt {
    color: var(--ink-500);
    font-weight: 700;
  }

  .context-fact dd {
    color: var(--ink-900);
    overflow-wrap: anywhere;
  }

  .context-state {
    display: inline-flex;
    align-items: center;
    gap: 0.375rem;
    font-weight: 700;
  }

  .status-dot {
    width: 0.5rem;
    height: 0.5rem;
    flex: none;
    border-radius: 50%;
    background: var(--ink-500);
  }

  .context-state.info .status-dot {
    background: var(--blue-500);
  }

  .context-state.status .status-dot {
    background: var(--green-500);
  }

  .context-state.caution .status-dot {
    background: var(--amber-500);
  }

  .context-state.status-alert .status-dot {
    background: var(--red-500);
  }

  .context-guidance {
    margin: 0.5rem 0 0;
    padding-top: 0.5rem;
    border-top: 1px solid var(--paper-200);
    color: var(--ink-700);
    font-size: 0.8125rem;
    line-height: 1.45;
  }

  @media (max-width: 1100px) {
    .context-rail {
      position: static;
      grid-column: 1 / -1;
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
    }

    .context-section {
      border-right: 1px solid var(--paper-200);
      border-bottom: 0;
    }

    .context-section:last-child {
      border-right: 0;
    }
  }

  @media (max-width: 820px) {
    .context-rail {
      grid-template-columns: minmax(0, 1fr);
    }

    .context-section {
      border-right: 0;
      border-bottom: 1px solid var(--paper-200);
    }

    .context-section:last-child {
      border-bottom: 0;
    }
  }

  @media (max-width: 620px) {
    .context-rail {
      order: 2;
      width: 100%;
    }

    .context-section {
      padding: 0.75rem;
    }
  }
</style>
