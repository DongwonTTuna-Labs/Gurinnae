<script lang="ts">
import { decisionCode, requiresDecisionReason } from "../decision-contract";
import type { ScreenRuntime, ScreenViewModel } from "../index";
import { humanFieldLabel } from "../screen-contract";

let {
  screen,
  runtime,
  dialogId = "decision-dialog",
}: {
  screen: ScreenViewModel;
  runtime: ScreenRuntime;
  dialogId?: string;
} = $props();
let dialog = $state<HTMLDialogElement>();
let opener = $state<HTMLElement>();
let selected = $state<string>("");
let reason = $state("");
const baseDecisionAction = $derived(
  screen.actions.find((action) => action.id === "submit-action-decision"),
);
const decisionActions = $derived.by(() => {
  const declared = screen.actions.filter((action) =>
    [
      "approve",
      "request-changes",
      "reject",
      "recuse",
      "accept-suggestion",
      "reject-suggestion",
    ].includes(action.id),
  );
  if (declared.length > 0 || !baseDecisionAction) return declared;
  if (
    runtime.allowedActionIds !== undefined &&
    !runtime.allowedActionIds.includes(baseDecisionAction.id)
  )
    return [];
  return [
    { ...baseDecisionAction, id: "approve", label: "승인" },
    { ...baseDecisionAction, id: "request-changes", label: "변경 요청" },
    { ...baseDecisionAction, id: "reject", label: "반려" },
    { ...baseDecisionAction, id: "recuse", label: "기피" },
  ];
});
const hasDecision = $derived(decisionActions.length > 0);
const fieldsFor = (id: string) =>
  runtime.forms[id] ?? runtime.forms["submit-action-decision"] ?? [];
const action = $derived(decisionActions.find((item) => item.id === selected));
const question = $derived(
  action?.id === "approve" || action?.id === "accept-suggestion"
    ? "이 제안을 승인하시겠습니까?"
    : action
      ? `이 제안에 ${action.label} 결정을 기록하시겠습니까?`
      : "이 결정을 기록하시겠습니까?",
);
const submitLabel = $derived(
  action?.id === "approve" || action?.id === "accept-suggestion"
    ? "예, 승인 기록"
    : action
      ? `아니오, ${action.label}`
      : "결정 기록",
);
const open = (id: string) => {
  opener =
    document.activeElement instanceof HTMLElement
      ? document.activeElement
      : undefined;
  selected = id;
  reason = "";
  dialog?.showModal();
};
const close = () => dialog?.close();
</script>

{#if hasDecision}
  <div class="decision-actions" data-testid="decision-actions" aria-label="결정 선택">
    <p class="decision-instruction">현재 근거 버전과 독립성을 확인한 뒤 하나의 결정을 선택하고, 승인 이외의 결정에는 이유를 남깁니다.</p>
    <div class="decision-button-row">
      {#each decisionActions as item (item.id)}
        <button
          type="button"
          class:item-primary={item.id === "approve"}
          class="decision-button"
          data-decision={item.id}
          aria-haspopup="dialog"
          onclick={() => open(item.id)}
        >{item.label}</button>
      {/each}
    </div>
  </div>
  <dialog bind:this={dialog} id={dialogId} class="decision-dialog" aria-labelledby={`${dialogId}-title`} aria-describedby={`${dialogId}-description`} onclose={() => { selected = ""; opener?.focus(); }}>
    <form method="POST" action={action ? `?/${baseDecisionAction?.id ?? action.id}` : "?"}>
      <h2 id={`${dialogId}-title`}>{action?.label ?? "결정"}</h2>
      <p id={`${dialogId}-description`} class="decision-question">{question}</p>
      <p>대상: {screen.title}. 예·아니오 선택은 현재 표시된 snapshot과 권한에 결합되어 기록됩니다.</p>
      {#if runtime.csrfToken}<input type="hidden" name="csrfToken" value={runtime.csrfToken} />{/if}
      {#if action && runtime.idempotencyKeys?.[action.id]}<input type="hidden" name="idempotencyKey" value={runtime.idempotencyKeys[action.id]} />{/if}
      <input type="hidden" name="decision" value={decisionCode(selected)} />
      {#each (action ? fieldsFor(action.id) : []) as field (field.name)}
        {#if field.name !== "reason" && field.name !== "decision" && !field.readonly}
          <label><span>{field.label && field.label !== field.name ? field.label : humanFieldLabel(field.name)}{field.required ? " (필수)" : ""}</span>
            {#if field.options}<select name={field.name} required={field.required}>{#each field.options as option}<option value={option}>{option}</option>{/each}</select>
            {:else if field.type === "json"}<textarea name={field.name} rows="4" required={field.required}></textarea>
            {:else if field.type === "boolean"}<input type="checkbox" name={field.name} value="true" />
            {:else}<input type={field.type} name={field.name} required={field.required} value={field.value ?? ""} />{/if}
          </label>
        {:else if field.name !== "decision" && field.readonly}
          <input type="hidden" name={field.name} value={field.value ?? ""} />
        {/if}
      {/each}
      <label class="reason-field"><span>결정 이유{requiresDecisionReason(selected) ? " (필수)" : " (선택)"}</span><textarea name="reason" rows="5" bind:value={reason} required={requiresDecisionReason(selected)} placeholder="근거 버전, 확인한 사실, 다음 담당자가 알아야 할 이유를 적습니다."></textarea></label>
      <div class="dialog-actions"><button type="button" class="secondary-button" onclick={close}>취소</button><button type="submit" class="primary-button">{submitLabel}</button></div>
    </form>
  </dialog>
{/if}
