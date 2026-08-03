<script lang="ts">
import type { ScreenViewModel } from "../../index";
import type { ResponseAccessPrimaryAction } from "../../response-access-action";
import type { ScreenProjection } from "../../screen-projection";

let {
  screen,
  projection,
  message,
  action = undefined,
}: {
  screen: ScreenViewModel;
  projection: ScreenProjection;
  message: string;
  action?: ResponseAccessPrimaryAction | undefined;
} = $props();
const stateTestId = $derived(`${screen.id.toLowerCase()}__state_live`);
</script>

<p
  id={projection.focus.stateLive}
  class="notice access-guidance"
  role="status"
  data-state="unauthenticated"
  data-testid={stateTestId}
  data-focus-target={projection.focus.stateLive}
  aria-live="polite"
>
  {message}
</p>
{#if action}
  <a
    id={`action-${action.id}`}
    class="primary-button access-guidance-action"
    href={action.href}
    data-action-id={action.id}
  >{action.label}</a>
{/if}

<style>
  .access-guidance {
    margin-block: 0 0.5rem;
  }

  .access-guidance-action {
    display: inline-flex;
    margin-block: 0 0.5rem;
  }
</style>
