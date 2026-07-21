<script lang="ts">
import type { ScreenField, ScreenRuntime, ScreenViewModel } from "../index";
import { localActionHref } from "../local-actions";
import {
  formFieldId,
  humanFieldLabel,
  typedScreenViewModel,
} from "../screen-contract";
import BotChallenge from "./BotChallenge.svelte";
import StructuredJsonField from "./StructuredJsonField.svelte";

let { screen, runtime }: { screen: ScreenViewModel; runtime: ScreenRuntime } =
  $props();
const fieldsFor = (actionId: string): readonly ScreenField[] =>
  runtime.forms[actionId] ?? [];
const operationId = (action: ScreenViewModel["actions"][number]) =>
  typeof action.operation_id === "string"
    ? action.operation_id
    : runtime.formOperationIds?.[action.id];
const interactionKind = (action: ScreenViewModel["actions"][number]) =>
  typeof action.interaction_kind === "string"
    ? action.interaction_kind
    : "NAVIGATION";
type AutoCompleteToken =
  | "email"
  | "tel"
  | "given-name"
  | "family-name"
  | "name"
  | "language"
  | "off";
const autocompleteFor = (name: string): AutoCompleteToken => {
  const normalized = name.toLowerCase();
  if (normalized.includes("email")) return "email";
  if (normalized.includes("phone") || normalized.includes("tel")) return "tel";
  if (normalized.includes("first") && normalized.includes("name"))
    return "given-name";
  if (normalized.includes("last") && normalized.includes("name"))
    return "family-name";
  if (normalized === "name" || normalized.endsWith("name")) return "name";
  if (normalized.includes("locale") || normalized.includes("language"))
    return "language";
  return "off";
};
const hrefFor = (action: ScreenViewModel["actions"][number]) =>
  localActionHref(screen, runtime, action);
const formAction = (actionId: string) => {
  const search = runtime.search ?? "";
  const query = search
    .replace(/^\?/, "")
    .split("&")
    .filter((part) => part && !part.startsWith("/") && !part.startsWith("%2F"))
    .join("&");
  // SvelteKit resolves a named action from the first query key (`/`).  Keep
  // it first when preserving a selected target or filter query; putting the
  // action after `proposalId=...` turns the POST into an unnamed action.
  return query ? `?/${actionId}&${query}` : `?/${actionId}`;
};
let challengeReady = $state<Record<string, boolean>>({});
let challengeProof = $state<Record<string, string>>({});
const challengeField = (actionId: string) =>
  fieldsFor(actionId).find((field) => field.name === "abuseProof");
const attachmentUpload = $derived(runtime.attachmentUpload);
const attachmentRemoval = $derived(runtime.attachmentRemoval);
const hasValidationError = $derived(
  ["validation-error", "error", "conflict"].includes(runtime.state),
);
const invalidField = (actionId: string, field: ScreenField): boolean => {
  if (!hasValidationError || field.readonly) return false;
  const haystack = runtime.errors.join(" ").toLowerCase();
  const tokenMatch = [field.name, field.label]
    .filter(Boolean)
    .some((token) => haystack.includes(token.toLowerCase()));
  if (tokenMatch) return true;
  const firstEditable = fieldsFor(actionId).find(
    (candidate) => !candidate.readonly,
  );
  return firstEditable?.name === field.name;
};
const primaryActionId = $derived(typedScreenViewModel(screen).primaryActionId);
function appendChallengeProof(actionId: string, event: FormDataEvent) {
  const proof = challengeProof[actionId];
  if (proof) event.formData.append("abuseProof", proof);
}
const supportsLocalCommand = (action: ScreenViewModel["actions"][number]) => {
  if (action.id.startsWith("copy-")) return true;
  if (
    [
      "clear",
      "retry",
      "discard-change",
      "discard-local",
    ].includes(action.id)
  )
    return true;
  if (action.id === "open-evidence") return hrefFor(action) !== undefined;
  return false;
};
const visibleActions = $derived(
  screen.actions
    // DecisionReviewPanel owns the single approval dialog and its form. Keeping
    // decision mutations out of this generic command rail prevents a second
    // direct POST path that could bypass the required reason/step-up UX.
    .filter(
      (action) =>
        ![
          "approve",
          "reject",
          "request-changes",
          "recuse",
          "accept-suggestion",
          "reject-suggestion",
        ].includes(action.id),
    )
    // INT-002 owns its decision mutation in ApprovalDecisionDialog. Other
    // destructive routes (for example REV-003 publication) still need their
    // server-bound form in the action rail; hiding every destructive action
    // made the publish flow impossible to start from the screen.
    .filter(
      (action) =>
        !(
          screen.id === "INT-002" &&
          interactionKind(action) === "DESTRUCTIVE_CONFIRMATION"
        ),
    )
    .filter((action) => action.id !== attachmentUpload?.actionId)
    .filter((action) => action.id !== attachmentRemoval?.actionId)
    .filter((action) => action.id !== "select-file")
    .filter(
      (action) => !(screen.id === "RSP-003" && action.id === "save-draft"),
    )
    .filter((action) => {
      if (runtime.allowedActionIds)
        return runtime.allowedActionIds.includes(action.id);
      if (runtime.state !== "unauthenticated") return true;
      return screen.id.startsWith("AUTH-") || !operationId(action);
    })
    .filter(
      (action) =>
        operationId(action) ||
        interactionKind(action) === "DOWNLOAD" ||
        (interactionKind(action) === "COMMAND" &&
          supportsLocalCommand(action)) ||
        hrefFor(action) !== undefined,
    ),
);

function runLocalCommand(action: ScreenViewModel["actions"][number]) {
  if (typeof window === "undefined") return;
  if (action.id.startsWith("copy-")) {
    const evidence = runtime.projection
      ? Object.values(runtime.projection.sections)
          .flatMap((section) => Object.values(section.fields))
          .filter((field) => field.known && field.value !== null)
          .map((field) => `${field.value} (${field.source})`)
          .join("\n")
      : "서버 권위 projection을 확인할 수 없습니다.";
    void navigator.clipboard.writeText(
      `${screen.title}\n${window.location.href}\n\n근거·식별자\n${evidence}`,
    );
    return;
  }
  if (action.id === "clear") {
    window.location.assign(runtime.pathname ?? screen.route);
    return;
  }
  if (action.id === "retry") {
    window.location.reload();
    return;
  }
  if (action.id === "discard-change") {
    window.location.reload();
    return;
  }
  if (action.id === "discard-local") {
    const prefix = `gurine:${screen.id}:`;
    for (const storage of [window.sessionStorage, window.localStorage]) {
      for (let index = storage.length - 1; index >= 0; index -= 1) {
        const key = storage.key(index);
        if (key?.startsWith(prefix)) storage.removeItem(key);
      }
    }
    window.location.assign("/auth/sign-in");
    return;
  }
  if (action.id === "open-evidence") {
    const destination = hrefFor(action);
    if (destination) window.location.assign(destination);
  }
}

function downloadHref(
  action: ScreenViewModel["actions"][number],
): string | undefined {
  if (screen.id === "PUB-021" && action.id === "download-openapi") {
    return "/api/openapi.json";
  }
  const encoded = runtime.downloads?.[action.id];
  return encoded ? `data:${encoded.mime};base64,${encoded.binary}` : undefined;
}
</script>

{#if visibleActions.length > 0 || attachmentUpload || attachmentRemoval}
  <section id="page-actions" class="command-panel" class:response-actions={screen.id.startsWith("RSP-")} aria-labelledby="command-heading" data-component="GuidedFormSection" data-testid="screen-actions">
    <div class="section-content">
      <p class="component-kicker">다음 단계</p><h2 id="command-heading">화면 작업</h2>
      <div class="action-grid">
        {#if attachmentUpload}
            <form id={`action-${attachmentUpload.actionId}`} method="POST" action={formAction(attachmentUpload.actionId)} enctype="multipart/form-data" data-action-id={attachmentUpload.actionId}>
            {#if runtime.csrfToken}<input type="hidden" name="csrfToken" value={runtime.csrfToken} />{/if}
            <h3>{attachmentUpload.label}</h3>
            <p>파일은 서버 경계를 통해 전송되며 체크섬과 크기가 일치한 경우에만 격리 저장소에서 검사를 시작합니다.</p>
            {#if runtime.idempotencyKeys?.[attachmentUpload.actionId]}<input type="hidden" name="idempotencyKey" value={runtime.idempotencyKeys[attachmentUpload.actionId]} />{/if}
            <label><span>첨부 파일 (필수, 최대 {Math.floor(attachmentUpload.maxBytes / 1_048_576)} MiB)</span><input type="file" name="attachment" accept={attachmentUpload.accept} required /></label>
            <button class={attachmentUpload.actionId === primaryActionId ? "primary-button" : "secondary-button"} type="submit">{attachmentUpload.label}</button>
          </form>
        {/if}
        {#if attachmentRemoval}
          {#if attachmentRemoval.items.length === 0}
            <div class="data-card" data-testid="attachment-list-empty">
              <h3>업로드된 첨부 파일</h3>
              <p>현재 초안에 연결된 첨부 파일이 없습니다.</p>
            </div>
          {:else}
            {#each attachmentRemoval.items as item (item.id)}
              <form id={`action-${attachmentRemoval.actionId}-${item.id}`} method="POST" action={formAction(attachmentRemoval.actionId)} data-action-id={attachmentRemoval.actionId} data-attachment-id={item.id}>
                {#if runtime.csrfToken}<input type="hidden" name="csrfToken" value={runtime.csrfToken} />{/if}
                <h3>{item.filename}</h3>
                <p>
                  {item.mediaType ?? "파일"}
                  {#if item.sizeBytes !== undefined} · {Math.ceil(item.sizeBytes / 1024).toLocaleString()} KiB{/if}
                  {#if item.uploadStatus} · 업로드 {item.uploadStatus}{/if}
                  {#if item.scanStatus} · 검사 {item.scanStatus}{/if}
                </p>
                {#if runtime.idempotencyKeys?.[attachmentRemoval.actionId]}<input type="hidden" name="idempotencyKey" value={runtime.idempotencyKeys[attachmentRemoval.actionId]} />{/if}
                <input type="hidden" name="attachmentId" value={item.id} />
                <button class="secondary-button" type="submit">{attachmentRemoval.label}</button>
              </form>
            {/each}
          {/if}
        {/if}
        {#each visibleActions as action (action.id)}
          {#if operationId(action)}
            <form id={`action-${action.id}`} method="POST" action={formAction(action.id)} data-action-id={action.id} onformdata={(event) => appendChallengeProof(action.id, event)}>
              {#if runtime.csrfToken}<input type="hidden" name="csrfToken" value={runtime.csrfToken} />{/if}
              <h3>{action.label}</h3>
              {#if runtime.idempotencyKeys?.[action.id]}<input type="hidden" name="idempotencyKey" value={runtime.idempotencyKeys[action.id]} />{/if}
              <p id={`action-${action.id}-field-help`} class="field-help" class:field-error={hasValidationError} aria-live="polite">{hasValidationError ? "입력값을 확인한 뒤 다시 시도하세요." : "필수 입력은 저장 전에 서버에서 다시 검증됩니다."}</p>
              {#each fieldsFor(action.id) as field (field.name)}
                {#if field.name === "abuseProof"}
                  <BotChallenge
                    config={runtime.botChallenge}
                    action={field.challengeAction ?? operationId(action) ?? "anonymousSubmission"}
                    onProof={(proof) => {
                      challengeReady[action.id] = proof.length > 0;
                      challengeProof[action.id] = proof;
                    }}
                  />
                {:else}<label for={formFieldId(screen.id, action.id, field.name)}><span>{field.label && field.label !== field.name ? field.label : humanFieldLabel(field.name)}{field.required ? " (필수)" : ""}</span>
                  {#if field.readonly}<input id={formFieldId(screen.id, action.id, field.name)} type="hidden" name={field.name} value={field.value ?? ""} readonly /><output>{field.value === undefined ? "—" : String(field.value)}</output>
                  {:else if field.type === "boolean" && !field.required}<select id={formFieldId(screen.id, action.id, field.name)} name={field.name} autocomplete={autocompleteFor(field.name)} aria-invalid={invalidField(action.id, field) ? "true" : undefined} aria-describedby={`action-${action.id}-field-help`}>
                    <option value="" selected={field.value === undefined}>변경 안 함</option>
                    <option value="true" selected={field.value === true}>예</option>
                    <option value="false" selected={field.value === false}>아니오</option>
                  </select>
                  {:else if field.type === "boolean"}<input id={formFieldId(screen.id, action.id, field.name)} type="checkbox" name={field.name} value="true" checked={field.value === true} aria-invalid={invalidField(action.id, field) ? "true" : undefined} aria-describedby={`action-${action.id}-field-help`} />
                  {:else if field.type === "json" && (field.name === "answers" || field.name.toLowerCase().includes("consent"))}<StructuredJsonField idPrefix={formFieldId(screen.id, action.id, field.name)} name={field.name} label={field.label && field.label !== field.name ? field.label : humanFieldLabel(field.name)} value={field.value} required={field.required} invalid={invalidField(action.id, field)} />
                  {:else if field.type === "json"}<textarea id={formFieldId(screen.id, action.id, field.name)} name={field.name} autocomplete={autocompleteFor(field.name)} required={field.required} rows="4" aria-invalid={invalidField(action.id, field) ? "true" : undefined} aria-describedby={`action-${action.id}-field-help`}>{typeof field.value === "string" ? field.value : ""}</textarea>
                  {:else if field.options}<select id={formFieldId(screen.id, action.id, field.name)} name={field.name} autocomplete={autocompleteFor(field.name)} required={field.required} aria-invalid={invalidField(action.id, field) ? "true" : undefined} aria-describedby={`action-${action.id}-field-help`}>{#each field.options as option}<option value={option} selected={String(field.value ?? "") === option}>{option}</option>{/each}</select>
                  {:else}<input id={formFieldId(screen.id, action.id, field.name)} type={field.type} name={field.name} autocomplete={autocompleteFor(field.name)} required={field.required} readonly={field.readonly} value={field.value ?? ""} aria-invalid={invalidField(action.id, field) ? "true" : undefined} aria-describedby={`action-${action.id}-field-help`} />{/if}
                </label>{/if}
              {/each}
              <button class={action.id === primaryActionId ? "primary-button" : "secondary-button"} type="submit" disabled={Boolean(challengeField(action.id)) && !challengeReady[action.id]}>{action.label}</button>
            </form>
          {:else if interactionKind(action) === "DOWNLOAD" && downloadHref(action)}
            <a id={`action-${action.id}`} class="secondary-button local-action" href={downloadHref(action)} download={`${screen.id.toLowerCase()}-${action.id}`} data-action-id={action.id}>{action.label}</a>
          {:else if interactionKind(action) === "DOWNLOAD"}
            <div class="download-unavailable" role="status" data-action-id={action.id}><span>{action.label}</span><small>현재 다운로드를 준비할 수 없습니다. 잠시 후 화면을 새로고침해 다시 시도하세요.</small></div>
          {:else if interactionKind(action) === "COMMAND"}
            <button id={`action-${action.id}`} class="secondary-button local-action" type="button" onclick={() => runLocalCommand(action)} data-action-id={action.id}>{action.label}</button>
          {:else if hrefFor(action)}
            <a id={`action-${action.id}`} class="secondary-button local-action" href={hrefFor(action)} target={interactionKind(action) === "EXTERNAL_LINK" ? "_blank" : undefined} rel={interactionKind(action) === "EXTERNAL_LINK" ? "noreferrer" : undefined} data-action-id={action.id}>{action.label}</a>
          {/if}
        {/each}
      </div>
    </div>
  </section>
{/if}
