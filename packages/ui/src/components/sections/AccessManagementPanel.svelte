<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import OperationData from "../OperationData.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, screen, runtime, projection }: ScreenSectionProps = $props();
const initialAuth = $derived(
  screen.id === "AUTH-001" &&
    runtime.state === "unauthenticated" &&
    runtime.errors.length === 0,
);
</script>
<SectionHeading {section} kicker="접근 관리" /><div class="access-warning" role="note"><strong>최소 권한</strong><p>역할 변경은 사유, 만료, 추가 인증 및 감사 기록을 요구합니다.</p></div>{#if projection && !initialAuth}<OperationData {runtime} {projection} mode="table" emptyLabel="표시할 사용자 또는 역할이 없습니다." />{/if}

<style>
  .access-warning {
    display: grid;
    grid-template-columns: max-content minmax(0, 1fr);
    align-items: baseline;
    gap: 8px 16px;
    margin: 0 0 12px;
    padding: 8px 10px;
    border-block: 1px solid var(--paper-200);
    color: var(--ink-900);
    font-size: 0.875rem;
    line-height: 1.45;
  }

  .access-warning strong {
    color: var(--ink-500);
    font-size: 0.75rem;
    font-weight: 650;
  }

  .access-warning p {
    margin: 0;
  }

  @media (max-width: 620px) {
    .access-warning {
      grid-template-columns: 1fr;
      gap: 2px;
      padding-inline: 8px;
    }
  }

  @media (forced-colors: active) {
    .access-warning {
      border-color: CanvasText;
    }
  }
</style>
