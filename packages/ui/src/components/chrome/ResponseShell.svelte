<script lang="ts">
import type {
  ScreenRuntime,
  ScreenViewModel,
  TypedScreenViewModel,
} from "../../index";
import { isBusyState, responseStepForScreen } from "../../screen-chrome";
import type { ScreenProjection } from "../../screen-projection";
import ResponseHeader from "../ResponseHeader.svelte";
import ScreenHeading from "../screen/ScreenHeading.svelte";
import SectionList from "../screen/SectionList.svelte";
import StateBadge from "../screen/StateBadge.svelte";
import StateSummary from "../screen/StateSummary.svelte";
import ResponseProgress from "./ResponseProgress.svelte";

let {
  screen,
  runtime,
  contract,
  projection,
}: {
  screen: ScreenViewModel;
  runtime: ScreenRuntime;
  contract: TypedScreenViewModel;
  projection: ScreenProjection;
} = $props();
const responseStep = $derived(responseStepForScreen(screen.id));
const busy = $derived(isBusyState(runtime.state));
</script>

<div class="form-shell">
  <ResponseHeader requestLabel={contract.objectLabel} />
  <main id="main-content" data-testid={projection.focus.main} data-focus-target={projection.focus.main} class="form-main" data-screen-id={screen.id} data-archetype={screen.archetype} aria-busy={busy}>
    <ResponseProgress {responseStep} errorCount={runtime.errors.length} />
    <ScreenHeading variant="response" {screen} {runtime} {contract} {projection} {responseStep} />
    {#if screen.id !== "RSP-008"}<div class="request-summary"><strong>{contract.objectLabel}</strong><span>세션·권한·제출 기한은 제출 단계마다 서버가 다시 확인됩니다.</span></div>{/if}
    <StateBadge variant="live" {screen} {runtime} {projection} /><StateSummary {screen} {runtime} {projection} />
    <div class="form-card"><SectionList variant="form" {screen} {runtime} {contract} {projection} /></div>
  </main>
</div>

<style>
.form-shell {
  min-height: 100vh;
  background: var(--paper-50);
}

.form-main {
  max-width: 1120px;
  margin: auto;
  padding: 16px 20px 40px;
  overflow-wrap: anywhere;
}

.request-summary {
  margin: 0 0 10px;
  padding: 6px 0;
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 4px 10px;
  border-block: 1px solid var(--paper-200);
}

.request-summary strong,
.request-summary span {
  font-size: 0.8125rem;
  line-height: 1.45;
}

.request-summary strong {
  color: var(--ink-900);
}

.request-summary span {
  color: var(--ink-700);
}

.form-card {
  padding: 10px;
  border: 1px solid var(--paper-200);
  border-radius: var(--radius-sm);
  background: var(--paper-0);
}

@media (max-width: 620px) {
  .form-main {
    padding: 12px 14px 36px;
  }

  .request-summary {
    margin-bottom: 8px;
    padding-block: 5px;
  }

  .form-card {
    padding: 12px;
  }
}
</style>
