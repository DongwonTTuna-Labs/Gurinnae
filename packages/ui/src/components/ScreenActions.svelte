<script lang="ts">
import { presentEnumValue } from "../enum-presentation";
import type { ScreenField, ScreenRuntime, ScreenViewModel } from "../index";
import { localActionHref } from "../local-actions";
import { projectionScalarText } from "../projection-value";
import { publicSearchDownloadVisible } from "../public-search-actions";
import {
  autocompleteForField,
  displayReadonlyFieldValue,
} from "../screen-action-display";
import {
  formFieldId,
  humanFieldLabel,
  typedScreenViewModel,
} from "../screen-contract";
import BotChallenge from "./BotChallenge.svelte";
import RowSelectionNavigation from "./RowSelectionNavigation.svelte";
import StructuredJsonField from "./StructuredJsonField.svelte";

type ActionContext = "page" | "header" | "section";
let {
  screen,
  runtime,
  actionIds,
  attachments = true,
  context = "page",
}: {
  screen: ScreenViewModel;
  runtime: ScreenRuntime;
  actionIds?: readonly string[];
  attachments?: boolean;
  context?: ActionContext;
} = $props();
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
const hrefFor = (action: ScreenViewModel["actions"][number]) =>
  localActionHref(screen, runtime, action);
const optionsFor = (actionId: string) =>
  runtime.navigationOptions?.[actionId] ?? [];
const formAction = (actionId: string) => {
  const search = runtime.search ?? "";
  const query = search
    .replace(/^\?/, "")
    .split("&")
    .filter((part) => part && !part.startsWith("/") && !part.startsWith("%2F"))
    .join("&");
  // Named SvelteKit actions must remain the first query key.
  return query ? `?/${actionId}&${query}` : `?/${actionId}`;
};
const formCaption = (action: ScreenViewModel["actions"][number]) =>
  runtime.formCaptions?.[action.id] ??
  "필수 입력은 저장 전에 서버에서 다시 검증됩니다.";
let challengeReady = $state<Record<string, boolean>>({});
let challengeProof = $state<Record<string, string>>({});
const challengeField = (actionId: string) =>
  fieldsFor(actionId).find((field) => field.name === "abuseProof");
const requestedActionIds = $derived(actionIds ? new Set(actionIds) : undefined);
const attachmentUpload = $derived(
  attachments ? runtime.attachmentUpload : undefined,
);
const attachmentRemoval = $derived(
  attachments ? runtime.attachmentRemoval : undefined,
);
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
const actionButtonClass = (actionId: string) =>
  context !== "header" &&
  actionId === primaryActionId &&
  !screen.route.startsWith("/internal")
    ? "primary-button"
    : "secondary-button";
function appendChallengeProof(actionId: string, event: FormDataEvent) {
  const proof = challengeProof[actionId];
  if (proof) event.formData.append("abuseProof", proof);
}
const supportsLocalCommand = (action: ScreenViewModel["actions"][number]) => {
  if (action.id.startsWith("copy-")) return true;
  if (["clear", "retry", "discard-change", "discard-local"].includes(action.id))
    return true;
  if (action.id === "open-evidence") return hrefFor(action) !== undefined;
  return false;
};
const visibleActions = $derived(
  screen.actions
    .filter((action) => requestedActionIds?.has(action.id) ?? true)
    // Keep decision mutations in the single DecisionReviewPanel approval dialog.
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
    // INT-002 owns its decision mutation; other destructive routes keep this form.
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
    .filter((action) =>
      publicSearchDownloadVisible(
        screen.id,
        interactionKind(action),
        runtime.publicLedger?.rows.length ?? 0,
        runtime.state,
      ),
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
        optionsFor(action.id).length > 0 ||
        hrefFor(action) !== undefined,
    ),
);
function runLocalCommand(action: ScreenViewModel["actions"][number]) {
  if (typeof window === "undefined") return;
  if (action.id.startsWith("copy-")) {
    const evidence = runtime.projection
      ? Object.values(runtime.projection.sections)
          .flatMap((section) => Object.entries(section.fields))
          .filter(([, field]) => field.known && field.value !== null)
          .map(
            ([name, field]) =>
              `${projectionScalarText(name, field.value) ?? "구조화 자료"} (${field.source})`,
          )
          .join("\n")
      : "확인 가능한 근거가 없습니다.";
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
  return encoded
    ? `data:${encoded.mime};base64,${encoded.binary}`
    : hrefFor(action);
}
</script>
{#if visibleActions.length > 0 || attachmentUpload || attachmentRemoval}
  <svelte:element
    this={context === "page" ? "section" : "div"}
    id={context === "page" ? "page-actions" : undefined}
    class="command-panel"
    class:context-actions={context !== "page"}
    class:header-actions={context === "header"}
    class:section-actions={context === "section"}
    class:response-actions={context === "page" && screen.id.startsWith("RSP-")}
    aria-labelledby={context === "page" ? "command-heading" : undefined}
    aria-label={context === "header" ? "화면 동작" : context === "section" ? "섹션 동작" : undefined}
    data-component={context === "page" ? "GuidedFormSection" : undefined}
    data-testid={context === "page" ? "screen-actions" : undefined}
  >
    <div class="section-content">
      {#if context === "page"}<p class="component-kicker">다음 단계</p><h2 id="command-heading">처리</h2>{/if}
      <div class="action-grid">
        {#if attachmentUpload}
            <form id={`action-${attachmentUpload.actionId}`} method="POST" action={formAction(attachmentUpload.actionId)} enctype="multipart/form-data" data-action-id={attachmentUpload.actionId}>
            {#if runtime.csrfToken}<input type="hidden" name="csrfToken" value={runtime.csrfToken} />{/if}
            <h3>{attachmentUpload.label}</h3>
            <p>파일은 서버 경계를 통해 전송되며 체크섬과 크기가 일치한 경우에만 격리 저장소에서 검사를 시작합니다.</p>
            {#if runtime.idempotencyKeys?.[attachmentUpload.actionId]}<input type="hidden" name="idempotencyKey" value={runtime.idempotencyKeys[attachmentUpload.actionId]} />{/if}
            <label><span>첨부 파일 (필수, 최대 {Math.floor(attachmentUpload.maxBytes / 1_048_576)} MiB)</span><input type="file" name="attachment" accept={attachmentUpload.accept} required /></label>
            <button class={actionButtonClass(attachmentUpload.actionId)} type="submit">{attachmentUpload.label}</button>
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
                  {#if item.uploadStatus} · 업로드 {projectionScalarText("uploadStatus", item.uploadStatus) ?? "확인 필요"}{/if}
                  {#if item.scanStatus} · 검사 {projectionScalarText("scanStatus", item.scanStatus) ?? "확인 필요"}{/if}
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
            {#if screen.id === "RSP-008" && action.id === "request-new-link"}<span id="new-link" class="fragment-anchor" aria-hidden="true"></span>{/if}
            {#if screen.id === "RSP-008" && action.id === "contact-owner"}<span id="contact" class="fragment-anchor" aria-hidden="true"></span>{/if}
            <form id={`action-${action.id}`} method="POST" action={formAction(action.id)} data-action-id={action.id} onformdata={(event) => appendChallengeProof(action.id, event)}>
              {#if runtime.csrfToken}<input type="hidden" name="csrfToken" value={runtime.csrfToken} />{/if}
              <h3>{action.label}</h3>
              {#if runtime.idempotencyKeys?.[action.id]}<input type="hidden" name="idempotencyKey" value={runtime.idempotencyKeys[action.id]} />{/if}
              <p id={`action-${action.id}-field-help`} class="field-help" class:field-error={hasValidationError} aria-live="polite">{hasValidationError ? "입력값을 확인한 뒤 다시 시도하세요." : formCaption(action)}</p>
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
                {:else}<label for={formFieldId(screen.id, action.id, field.name)}><span>{humanFieldLabel(field.name)}{field.required ? " (필수)" : ""}</span>
                  {#if field.readonly}<input id={formFieldId(screen.id, action.id, field.name)} type="hidden" name={field.name} value={field.value ?? ""} readonly /><output>{displayReadonlyFieldValue(field)}</output>
                  {:else if field.type === "boolean" && !field.required}<select id={formFieldId(screen.id, action.id, field.name)} name={field.name} autocomplete={autocompleteForField(field.name)} aria-invalid={invalidField(action.id, field) ? "true" : undefined} aria-describedby={`action-${action.id}-field-help`}>
                    <option value="" selected={field.value === undefined}>변경 안 함</option>
                    <option value="true" selected={field.value === true}>예</option>
                    <option value="false" selected={field.value === false}>아니오</option>
                  </select>
                  {:else if field.type === "boolean"}<input id={formFieldId(screen.id, action.id, field.name)} type="checkbox" name={field.name} value="true" checked={field.value === true} aria-invalid={invalidField(action.id, field) ? "true" : undefined} aria-describedby={`action-${action.id}-field-help`} />
                  {:else if field.type === "json" && (field.name === "answers" || field.name.toLowerCase().includes("consent"))}<StructuredJsonField idPrefix={formFieldId(screen.id, action.id, field.name)} name={field.name} label={humanFieldLabel(field.name)} value={field.value} required={field.required} invalid={invalidField(action.id, field)} />
                  {:else if field.type === "json"}<textarea id={formFieldId(screen.id, action.id, field.name)} name={field.name} autocomplete={autocompleteForField(field.name)} required={field.required} rows="4" aria-invalid={invalidField(action.id, field) ? "true" : undefined} aria-describedby={`action-${action.id}-field-help`}>{typeof field.value === "string" ? field.value : ""}</textarea>
                  {:else if field.options}<select id={formFieldId(screen.id, action.id, field.name)} name={field.name} autocomplete={autocompleteForField(field.name)} required={field.required} aria-invalid={invalidField(action.id, field) ? "true" : undefined} aria-describedby={`action-${action.id}-field-help`}>{#if field.payloadPath && !field.required}<option value="" selected={field.value === undefined}>변경 안 함</option>{/if}{#each field.options as option}<option value={option} selected={String(field.value ?? "") === option}>{presentEnumValue(option)}</option>{/each}</select>
                  {:else}<input id={formFieldId(screen.id, action.id, field.name)} type={field.type} name={field.name} autocomplete={autocompleteForField(field.name)} required={field.required} readonly={field.readonly} value={field.value ?? ""} aria-invalid={invalidField(action.id, field) ? "true" : undefined} aria-describedby={`action-${action.id}-field-help`} />{/if}
                </label>{/if}
              {/each}
              <button class={actionButtonClass(action.id)} type="submit" disabled={Boolean(challengeField(action.id)) && !challengeReady[action.id]}>{action.label}</button>
            </form>
          {:else if interactionKind(action) === "DOWNLOAD" && downloadHref(action)}
            <a id={`action-${action.id}`} class="secondary-button local-action" href={downloadHref(action)} download={downloadHref(action)?.startsWith("data:") ? `${screen.id.toLowerCase()}-${action.id}` : undefined} data-action-id={action.id}>{action.label}</a>
          {:else if interactionKind(action) === "DOWNLOAD"}
            <div class="download-unavailable" role="status" data-action-id={action.id}><span>{action.label}</span><small>현재 다운로드를 준비할 수 없습니다. 잠시 후 화면을 새로고침해 다시 시도하세요.</small></div>
          {:else if interactionKind(action) === "COMMAND"}
            <button id={`action-${action.id}`} class="secondary-button local-action" type="button" onclick={() => runLocalCommand(action)} data-action-id={action.id}>{action.label}</button>
          {:else if optionsFor(action.id).length > 0}
            <RowSelectionNavigation actionId={action.id} actionLabel={action.label} options={optionsFor(action.id)} buttonClass={actionButtonClass(action.id)} external={interactionKind(action) === "EXTERNAL_LINK"} />
          {:else if hrefFor(action)}
            <a id={`action-${action.id}`} class="secondary-button local-action" href={hrefFor(action)} target={interactionKind(action) === "EXTERNAL_LINK" ? "_blank" : undefined} rel={interactionKind(action) === "EXTERNAL_LINK" ? "noopener noreferrer" : undefined} data-action-id={action.id}>{action.label}</a>
          {/if}
        {/each}
      </div>
    </div>
  </svelte:element>
{/if}
<style>
  .command-panel { padding-block: 0.5rem 0; border-top: 1px solid var(--paper-200); }
  .header-actions { margin-block: 0.25rem 0.5rem; padding-block: 0; border-top: 0; }
  .section-actions { margin-top: 0.5rem; }
  .section-content { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 0.25rem 0.625rem; align-items: baseline; }
  .component-kicker, h2, h3, p { margin: 0; }
  .component-kicker { color: var(--ink-500); font-size: 0.75rem; font-weight: 650; letter-spacing: 0.04em; }
  h2, h3 { font-weight: 650; }
  h2 { font-size: 1.125rem; }
  h3 { font-size: 1rem; }
  .action-grid { display: grid; grid-column: 1 / -1; grid-template-columns: repeat(auto-fit, minmax(min(100%, 20rem), 1fr)); gap: 0 1rem; }
  .action-grid form,
  .data-card,
  .download-unavailable {
    min-width: 0;
    padding-block: 0.5rem;
    border-top: 1px solid var(--paper-200);
  }
  .action-grid form { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 14rem), 1fr)); align-content: start; gap: 0.375rem 0.75rem; }
  .action-grid form:has(> label:nth-of-type(4)) { grid-column: 1 / -1; }
  .action-grid textarea { height: var(--target-min); min-height: var(--target-min); }
  .action-grid form > h3, .action-grid form > p, .action-grid form > button,
  .action-grid form > :global(.bot-challenge),
  .action-grid form > :global(.structured-json-field) {
    grid-column: 1 / -1;
  }
  .action-grid form > p, .data-card p, .download-unavailable small {
    color: var(--ink-700);
    font-size: 0.8125rem;
    line-height: 1.5;
  }
  .action-grid label {
    display: grid;
    gap: 0.25rem;
    color: var(--ink-900);
    font-size: 0.8125rem;
    font-weight: 650;
  }
  output {
    min-height: 2.5rem;
    padding: 0.625rem 0.75rem;
    border: 1px solid var(--paper-200);
    border-radius: var(--radius-sm);
    background: var(--paper-50);
    overflow-wrap: anywhere;
  }
  .field-help, .download-unavailable small { font-size: 0.75rem; }
  .local-action, .action-grid form > button { align-self: start; justify-self: start; }
  .local-action { margin-top: 0.625rem; }
  .header-actions .section-content { display: block; }
  .header-actions .action-grid { display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 0.375rem; }
  .header-actions .local-action { margin-top: 0; }
  .header-actions .download-unavailable { padding-block: 0; border-top: 0; }
  .download-unavailable { display: grid; gap: 0.25rem; }
  .fragment-anchor { display: block; scroll-margin-top: 1.25rem; }
  .response-actions {
    position: sticky;
    bottom: 0;
    z-index: 10;
    margin-inline: -1rem;
    padding: 0.75rem 1rem;
    background: var(--paper-25);
  }
  @media (max-width: 620px) {
    .section-content,
    .action-grid {
      grid-template-columns: minmax(0, 1fr);
    }
    .action-grid form { grid-template-columns: minmax(0, 1fr); }
    .action-grid label,
    .local-action,
    .action-grid form > button {
      min-height: 44px;
    }
  }
  @media (forced-colors: active) {
    .action-grid form, .data-card, .download-unavailable, output { border-color: CanvasText; background: Canvas; color: CanvasText; }
  }
</style>
