<script lang="ts">
import type {
  ScreenRuntime,
  ScreenViewModel,
  TypedScreenViewModel,
} from "../../index";
import type { ScreenProjection } from "../../screen-projection";
import Breadcrumb from "../chrome/Breadcrumb.svelte";

let {
  variant,
  screen,
  runtime,
  contract,
  projection,
  responseStep = 0,
}: {
  variant: "public-home" | "public" | "response" | "auth" | "internal";
  screen: ScreenViewModel;
  runtime: ScreenRuntime;
  contract: TypedScreenViewModel;
  projection: ScreenProjection;
  responseStep?: number;
} = $props();
const headingTestId = $derived(`${screen.id.toLowerCase()}__heading`);
</script>

{#if variant === "public-home"}
  <header class="home-heading">
    <h1 id={headingTestId} data-testid={projection.focus.heading} data-focus-target={projection.focus.heading}>공개 기록 대장</h1>
    <p class="home-safety">자동 부패 판정기가 아닙니다 — 가격 차이나 반복 계약은 조사 신호일 뿐 위법·비리를 의미하지 않습니다.</p>
  </header>
{:else if variant === "public"}
  <header class="page-heading" data-journey={contract.journey}><Breadcrumb {screen} {runtime} /><h1 id={headingTestId} data-testid={projection.focus.heading} data-focus-target={projection.focus.heading}>{screen.title}</h1><p class="lead">{contract.answerFirst}</p></header>
{:else if variant === "response"}
  <header class="page-heading"><p class="eyebrow">{responseStep > 0 ? `${responseStep} / 5 · ` : ""}보호된 소명 절차</p><h1 id={headingTestId} data-testid={projection.focus.heading} data-focus-target={projection.focus.heading}>{screen.title}</h1><p class="lead">{contract.answerFirst}</p></header>
{:else if variant === "auth"}
  <header class="page-heading"><p class="eyebrow">보호된 내부 접근</p><h1 id={headingTestId} data-testid={projection.focus.heading} data-focus-target={projection.focus.heading}>{screen.title}</h1><p class="lead">{screen.sections[0]?.purpose ?? "조직 계정과 현재 보안 상태를 확인합니다."}</p></header>
{:else}
  <h1 id={headingTestId} data-testid={projection.focus.heading} data-focus-target={projection.focus.heading}>{screen.title}</h1>
{/if}

<style>
.home-heading {
  margin: 0 0 12px;
  padding: 10px 0;
  display: grid;
  grid-template-columns: minmax(12rem, auto) minmax(18rem, 1fr);
  gap: 16px;
  align-items: center;
  border-block: 1px solid var(--paper-200);
}

h1 {
  margin: 0;
  color: var(--ink-950);
  font-size: var(--text-h1, clamp(1.5rem, 2vw, 1.875rem));
  line-height: 1.2;
  letter-spacing: -0.025em;
}

.home-safety {
  max-width: 68ch;
  margin: 0 0 0 auto;
  color: var(--ink-700);
  font-size: 0.8125rem;
  line-height: 1.55;
  text-align: right;
}

.page-heading {
  max-width: 62rem;
  margin: 0 0 12px;
}

.eyebrow {
  margin: 0 0 3px;
  color: var(--ink-500);
  font-size: 0.75rem;
  font-weight: 650;
  line-height: 1.4;
}

.page-heading h1 {
  margin-bottom: 4px;
}

.lead {
  max-width: 72ch;
  margin: 0;
  color: var(--ink-700);
  font-size: 0.9375rem;
  line-height: 1.5;
}

@media (max-width: 620px) {
  .home-heading {
    grid-template-columns: 1fr;
    gap: 6px;
    padding: 8px 0;
  }

  .home-safety {
    margin: 0;
    text-align: left;
  }

  .page-heading {
    margin-bottom: 10px;
  }
}
</style>
