<script lang="ts">
import type { ScreenField, ScreenRuntime, ScreenViewModel } from "../index";

let { screen, runtime }: { screen: ScreenViewModel; runtime: ScreenRuntime } =
  $props();
const fieldsFor = (actionId: string): readonly ScreenField[] =>
  runtime.forms[actionId] ?? [];
const operationId = (action: ScreenViewModel["actions"][number]) =>
  typeof action.operation_id === "string" ? action.operation_id : undefined;
const visibleActions = $derived(
  screen.actions.filter((action) => {
    if (runtime.allowedActionIds)
      return runtime.allowedActionIds.includes(action.id);
    if (runtime.state !== "unauthenticated") return true;
    return screen.id.startsWith("AUTH-") || !operationId(action);
  }),
);
</script>

{#if visibleActions.length > 0}
  <section id="page-actions" class="command-panel" aria-labelledby="command-heading" data-component="GuidedFormSection" data-testid="screen-actions">
    <div class="section-content">
      <p class="component-kicker">다음 단계</p><h2 id="command-heading">화면 작업</h2>
      <div class="action-grid">
        {#each visibleActions as action (action.id)}
          {#if operationId(action)}
            <form method="POST" action={`?/${action.id}`} data-action-id={action.id}>
              <h3>{action.label}</h3>
              {#if runtime.csrfToken}<input type="hidden" name="csrfToken" value={runtime.csrfToken} />{/if}
              {#each fieldsFor(action.id) as field (field.name)}
                <label><span>{field.label}{field.required ? " (필수)" : ""}</span>
                  {#if field.type === "boolean"}<input type="checkbox" name={field.name} value="true" checked={field.value === true} />
                  {:else if field.type === "json"}<textarea name={field.name} required={field.required} rows="4">{typeof field.value === "string" ? field.value : ""}</textarea>
                  {:else if field.options}<select name={field.name} required={field.required}>{#each field.options as option}<option value={option}>{option}</option>{/each}</select>
                  {:else}<input type={field.type} name={field.name} required={field.required} value={field.value ?? ""} />{/if}
                </label>
              {/each}
              <button class="primary-button" type="submit">{action.label}</button>
            </form>
          {:else}
            <a class="secondary-button local-action" href={`${runtime.pathname ?? screen.route}?action=${encodeURIComponent(action.id)}`} data-action-id={action.id}>{action.label}</a>
          {/if}
        {/each}
      </div>
    </div>
  </section>
{/if}
