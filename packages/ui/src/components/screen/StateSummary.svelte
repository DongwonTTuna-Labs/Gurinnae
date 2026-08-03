<script lang="ts">
import type { ScreenRuntime, ScreenViewModel } from "../../index";
import { errorTargetForMessage } from "../../screen-chrome";
import type { ScreenProjection } from "../../screen-projection";

let {
  screen,
  runtime,
  projection,
}: {
  screen: ScreenViewModel;
  runtime: ScreenRuntime;
  projection: ScreenProjection;
} = $props();
const errorTestId = $derived(`${screen.id.toLowerCase()}__error_summary`);
const errorTarget = (message: string) =>
  errorTargetForMessage(screen, runtime, message);
</script>

{#if runtime.notice}<p class="notice" role="status">{runtime.notice}</p>{/if}
{#if runtime.errors.length > 0}
  <div id={projection.focus.errorSummary} class="error-summary" role="alert" tabindex="-1" data-testid={errorTestId} data-focus-target={projection.focus.errorSummary}><h2>요청을 완료하지 못했습니다</h2><ul>{#each runtime.errors as error, index}<li>{#if errorTarget(error)}<a href={`#${errorTarget(error)}`}>오류 {index + 1}: {error}</a>{:else}{error}{/if}</li>{/each}</ul></div>
{/if}
