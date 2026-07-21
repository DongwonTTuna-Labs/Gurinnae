<script lang="ts">
import { tick } from "svelte";
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
let dialogTitle = $state<HTMLElement>();
let opener = $state<HTMLElement>();
let selected = $state<string>("");
let reason = $state("");
let changeTasks = $state("[]");
let conflictDeclarationId = $state("");
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
const hasValidationError = $derived(
  ["validation-error", "error", "conflict"].includes(runtime.state),
);
const fieldHelpId = $derived(`${dialogId}-field-help`);
const fieldsFor = (id: string) =>
  runtime.forms[id] ??
  (runtime.selectedTarget?.handoffId
    ? runtime.forms["decide-journey-handoff"]
    : undefined) ??
  runtime.forms["submit-action-decision"] ??
  [];
const selectedTarget = $derived(runtime.selectedTarget);
const journeyDecision = $derived(
  typeof selectedTarget?.handoffId === "string" &&
    selectedTarget.handoffId.length > 0 &&
    typeof selectedTarget.expectedHandoffVersion === "number" &&
    selectedTarget.expectedHandoffVersion >= 1 &&
    typeof selectedTarget.expectedBindingDigest === "string" &&
    /^[0-9a-f]{64}$/i.test(selectedTarget.expectedBindingDigest),
);
const selectedDecisionAction = $derived(
  decisionActions.find((item) => item.id === selected),
);
// Decision buttons (approve/reject/changes/recuse) are presentation choices,
// not SvelteKit action names.  Always submit through the server-declared
// command descriptor so a fallback button cannot post to `?/approve` (which
// is not an action registered by the route) and bypass the bound payload.
const commandAction = $derived(
  journeyDecision
    ? screen.actions.find((item) => item.id === "decide-journey-handoff")
    : (baseDecisionAction ?? selectedDecisionAction),
);
const action = $derived(
  journeyDecision ? commandAction : selectedDecisionAction,
);
const commandActionId = $derived(
  commandAction?.id ?? baseDecisionAction?.id ?? "",
);
const formAction = $derived.by(() => {
  const search = runtime.search ?? "";
  const query = search
    .replace(/^\?/, "")
    .split("&")
    .filter((part) => part && !part.startsWith("/") && !part.startsWith("%2F"))
    .join("&");
  return query ? `?/${commandActionId}&${query}` : `?/${commandActionId}`;
});
const wireDecision = $derived.by(() => {
  if (journeyDecision) {
    return JSON.stringify(
      selected === "approve" || selected === "accept-suggestion"
        ? "ACKNOWLEDGE"
        : "DECLINE",
    );
  }
  // The editorial review endpoint has a scalar, lower-case enum while the
  // action-proposal endpoint deliberately accepts the authority decision
  // object.  Keep the presentation ids independent from either wire shape.
  if (commandAction?.operation_id === "submitReview") {
    return selected === "approve" || selected === "accept-suggestion"
      ? "approve"
      : selected === "request-changes"
        ? "changes_required"
        : "reject";
  }
  const kind = decisionCode(selected);
  const base = {
    kind,
    reasonCode,
    reason,
  };
  if (kind === "APPROVE")
    return JSON.stringify({ ...base, attestExactPreview: true });
  if (kind === "CHANGES_REQUIRED") {
    let tasks: unknown[] = [];
    try {
      const parsed = JSON.parse(changeTasks);
      if (Array.isArray(parsed)) tasks = parsed;
    } catch {
      tasks = [];
    }
    return JSON.stringify({ ...base, changeTasks: tasks });
  }
  if (kind === "RECUSE")
    return JSON.stringify({ ...base, conflictDeclarationId });
  return base ? JSON.stringify(base) : "";
});
const reasonCode = $derived(
  selected === "approve" || selected === "accept-suggestion"
    ? ""
    : selected === "request-changes"
      ? "EVIDENCE_CHANGED"
      : selected === "recuse"
        ? "CONFLICT_OF_INTEREST"
        : "POLICY_BLOCKED",
);
const question = $derived(
  action?.id === "approve" ||
    action?.id === "accept-suggestion" ||
    (journeyDecision &&
      (selected === "approve" || selected === "accept-suggestion"))
    ? "이 제안을 승인하시겠습니까?"
    : action
      ? `이 제안에 ${action.label} 결정을 기록하시겠습니까?`
      : "이 결정을 기록하시겠습니까?",
);
const submitLabel = $derived(
  action?.id === "approve" ||
    action?.id === "accept-suggestion" ||
    (journeyDecision &&
      (selected === "approve" || selected === "accept-suggestion"))
    ? "예, 승인 기록"
    : action
      ? `아니오, ${action.label}`
      : "결정 기록",
);
const fieldId = (name: string) =>
  `${dialogId}-field-${name.replace(/[^a-zA-Z0-9_-]+/gu, "-")}`;
const fieldInvalid = (name: string) => {
  if (!hasValidationError) return false;
  const value = runtime.errors.join(" ").toLowerCase();
  return value.includes(name.toLowerCase()) || name === "reason";
};
const open = (id: string, event: MouseEvent) => {
  if (dialog?.open) return;
  opener =
    event.currentTarget instanceof HTMLElement
      ? event.currentTarget
      : undefined;
  selected = id;
  reason = "";
  changeTasks = "[]";
  conflictDeclarationId = "";
  dialog?.showModal();
  void tick().then(() => dialogTitle?.focus());
};
const close = () => dialog?.close();
const restoreOpener = () => {
  const target = opener;
  opener = undefined;
  selected = "";
  if (target?.isConnected && !target.hasAttribute("disabled")) {
    void tick().then(() => target.focus());
  }
};
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
          id={`action-${item.id}`}
          data-decision={item.id}
          aria-haspopup="dialog"
          onclick={(event) => open(item.id, event)}
        >{item.label}</button>
      {/each}
    </div>
  </div>
  <dialog bind:this={dialog} id={dialogId} class="decision-dialog" aria-modal="true" aria-labelledby={`${dialogId}-title`} aria-describedby={`${dialogId}-description`} data-focus-target={dialogId} onclose={restoreOpener}>
    <form method="POST" action={commandActionId ? formAction : "?"}>
      <h2 bind:this={dialogTitle} id={`${dialogId}-title`} tabindex="-1">{action?.label ?? "결정"}</h2>
      <p id={`${dialogId}-description`} class="decision-question">{question}</p>
      <p>대상: {screen.title}. 예·아니오 선택은 현재 표시된 snapshot과 권한에 결합되어 기록됩니다.</p>
      <p id={fieldHelpId} class="field-help" class:field-error={hasValidationError} aria-live="polite">{hasValidationError ? "입력값을 확인한 뒤 다시 시도하세요." : "결정 이유와 필수 항목은 저장 전에 다시 확인됩니다."}</p>
      {#if commandActionId && runtime.idempotencyKeys?.[commandActionId]}<input type="hidden" name="idempotencyKey" value={runtime.idempotencyKeys[commandActionId]} />{/if}
      {#if runtime.csrfToken}<input type="hidden" name="csrfToken" value={runtime.csrfToken} />{/if}
      <input type="hidden" name="decision" value={wireDecision} />
      {#if journeyDecision}
        <input type="hidden" name="schemaVersion" value={JSON.stringify("decide-journey-handoff.request.v1")} />
        <input type="hidden" name="handoffId" value={String(selectedTarget?.handoffId ?? "")} />
        <input type="hidden" name="expectedHandoffVersion" value={String(selectedTarget?.expectedHandoffVersion ?? "")} />
        <input type="hidden" name="expectedBindingDigest" value={String(selectedTarget?.expectedBindingDigest ?? "")} />
        <input type="hidden" name="reasonCode" value={reasonCode} />
      {/if}
      {#each (commandActionId ? fieldsFor(commandActionId) : []) as field (field.name)}
        {#if field.name !== "reason" && field.name !== "decision" && field.name !== "schemaVersion" && field.name !== "handoffId" && field.name !== "expectedHandoffVersion" && field.name !== "expectedBindingDigest" && field.name !== "reasonCode" && !field.readonly}
          <label for={fieldId(field.name)}><span>{field.label && field.label !== field.name ? field.label : humanFieldLabel(field.name)}{field.required ? " (필수)" : ""}</span>
            {#if field.options}<select id={fieldId(field.name)} name={field.name} required={field.required} aria-invalid={fieldInvalid(field.name) ? "true" : undefined} aria-describedby={fieldHelpId}>{#each field.options as option}<option value={option}>{option}</option>{/each}</select>
            {:else if field.type === "json"}<textarea id={fieldId(field.name)} name={field.name} rows="4" required={field.required} aria-invalid={fieldInvalid(field.name) ? "true" : undefined} aria-describedby={fieldHelpId}></textarea>
            {:else if field.type === "boolean"}<input id={fieldId(field.name)} type="checkbox" name={field.name} value="true" aria-invalid={fieldInvalid(field.name) ? "true" : undefined} aria-describedby={fieldHelpId} />
            {:else}<input id={fieldId(field.name)} type={field.type} name={field.name} required={field.required} value={field.value ?? ""} aria-invalid={fieldInvalid(field.name) ? "true" : undefined} aria-describedby={fieldHelpId} />{/if}
          </label>
        {:else if field.name !== "decision" && field.name !== "schemaVersion" && field.name !== "handoffId" && field.name !== "expectedHandoffVersion" && field.name !== "expectedBindingDigest" && field.name !== "reasonCode" && field.readonly}
          <input type="hidden" name={field.name} value={field.value ?? ""} />
        {/if}
      {/each}
      {#if journeyDecision && selected !== "approve" && selected !== "accept-suggestion"}
        <label for={fieldId("reasonCode")}><span>인계 거절 사유 코드 (필수)</span><select id={fieldId("reasonCode")} name="reasonCode" required aria-describedby={fieldHelpId}><option value={reasonCode}>{reasonCode}</option></select></label>
      {/if}
      {#if !journeyDecision}
        <label class="reason-field" for={fieldId("reason")}><span>결정 이유 (필수)</span><textarea id={fieldId("reason")} name="reason" rows="5" bind:value={reason} required aria-invalid={fieldInvalid("reason") ? "true" : undefined} aria-describedby={fieldHelpId} placeholder="근거 버전, 확인한 사실, 다음 담당자가 알아야 할 이유를 적습니다."></textarea></label>
        {#if selected === "request-changes"}
          <label for={fieldId("changeTasks")}><span>변경 작업 목록 (JSON, 최소 1개)</span><textarea id={fieldId("changeTasks")} name="changeTasks" rows="4" bind:value={changeTasks} required aria-invalid={fieldInvalid("changeTasks") ? "true" : undefined} aria-describedby={fieldHelpId}></textarea></label>
        {:else if selected === "recuse"}
          <label for={fieldId("conflictDeclarationId")}><span>이해충돌 선언 ID (UUID)</span><input id={fieldId("conflictDeclarationId")} name="conflictDeclarationId" type="text" bind:value={conflictDeclarationId} required aria-invalid={fieldInvalid("conflictDeclarationId") ? "true" : undefined} aria-describedby={fieldHelpId} /></label>
        {/if}
      {:else}
        <input type="hidden" name="reason" value="" />
      {/if}
      <div class="dialog-actions"><button type="button" class="secondary-button" onclick={close}>취소</button><button type="submit" class="primary-button">{submitLabel}</button></div>
    </form>
  </dialog>
{/if}
