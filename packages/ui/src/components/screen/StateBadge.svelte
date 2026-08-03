<script lang="ts">
import type { ScreenRuntime, ScreenViewModel } from "../../index";
import { stateTone } from "../../screen-chrome";
import { stateLabel } from "../../screen-contract";
import type { ScreenProjection } from "../../screen-projection";

let {
  variant,
  screen,
  runtime,
  projection,
}: {
  variant: "live" | "topbar";
  screen: ScreenViewModel;
  runtime: ScreenRuntime;
  projection: ScreenProjection;
} = $props();
const stateTestId = $derived(`${screen.id.toLowerCase()}__state_live`);
</script>

{#if variant === "live"}<p id={projection.focus.stateLive} class={`state badge ${stateTone(runtime.state)}`} data-state={runtime.state} data-testid={stateTestId} data-focus-target={projection.focus.stateLive} aria-live="polite">현재 상태: {stateLabel(runtime.state)}</p>{:else}<span class={`badge ${stateTone(runtime.state)}`}>{stateLabel(runtime.state)}</span>{/if}

<style>
  .badge {
    gap: 0.375rem;
  }

  .badge::before {
    width: 0.5rem;
    height: 0.5rem;
    flex: none;
    border-radius: 50%;
    background: currentColor;
    content: "";
  }

  .state {
    margin: 0 0 0.5rem;
    font-size: var(--text-meta, 0.75rem);
  }
</style>
