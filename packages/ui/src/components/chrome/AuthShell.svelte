<script lang="ts">
import type {
  ScreenRuntime,
  ScreenViewModel,
  TypedScreenViewModel,
} from "../../index";
import { isBusyState } from "../../screen-chrome";
import type { ScreenProjection } from "../../screen-projection";
import ResponseHeader from "../ResponseHeader.svelte";
import ScreenHeading from "../screen/ScreenHeading.svelte";
import SectionList from "../screen/SectionList.svelte";
import StateBadge from "../screen/StateBadge.svelte";
import StateSummary from "../screen/StateSummary.svelte";

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
const busy = $derived(isBusyState(runtime.state));
</script>

<div class="form-shell auth-shell">
  <ResponseHeader requestLabel="내부 인증" />
  <main id="main-content" data-testid={projection.focus.main} data-focus-target={projection.focus.main} class="form-main auth-main" data-screen-id={screen.id} data-archetype={screen.archetype} aria-busy={busy}>
    <ScreenHeading variant="auth" {screen} {runtime} {contract} {projection} />
    <StateBadge variant="live" {screen} {runtime} {projection} /><StateSummary {screen} {runtime} {projection} /><div class="form-card"><SectionList variant="form" {screen} {runtime} {contract} {projection} /></div>
  </main>
</div>

<style>
.form-shell {
  min-height: 100vh;
  background: var(--paper-50);
}

.form-main {
  max-width: 600px;
  margin: auto;
  padding: 16px 20px 40px;
  overflow-wrap: anywhere;
}

.form-card {
  padding: 14px;
  border: 1px solid var(--paper-200);
  border-radius: var(--radius-sm);
  background: var(--paper-0);
}

@media (max-width: 620px) {
  .form-main {
    padding: 12px 14px 36px;
  }

  .form-card {
    padding: 12px;
  }
}
</style>
