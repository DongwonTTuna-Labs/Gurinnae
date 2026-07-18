<script lang="ts">
import type { ScreenField, ScreenRuntime, ScreenViewModel } from "../index";
import { localActionHref } from "../local-actions";
import { humanFieldLabel } from "../screen-contract";
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
const hrefFor = (action: ScreenViewModel["actions"][number]) =>
  localActionHref(screen, runtime, action);
let challengeReady = $state<Record<string, boolean>>({});
const challengeField = (actionId: string) =>
  fieldsFor(actionId).find((field) => field.name === "abuseProof");
const attachmentUpload = $derived(runtime.attachmentUpload);
const attachmentRemoval = $derived(runtime.attachmentRemoval);
const hasSearchForm = $derived(
  screen.sections.some((section) => section.component === "UnifiedSearch"),
);
const supportsLocalCommand = (action: ScreenViewModel["actions"][number]) => {
  if (action.id.startsWith("copy-")) return true;
  if (
    [
      "clear",
      "retry",
      "discard-change",
      "discard-local",
      "view-compact",
    ].includes(action.id)
  )
    return true;
  if (action.id === "open-evidence") return hrefFor(action) !== undefined;
  if (action.id.includes("search") || action.id.includes("filter"))
    return hasSearchForm;
  return false;
};
const visibleActions = $derived(
  screen.actions
    // DecisionReviewPanel owns the single approval dialog and its form. Keeping
    // decision mutations out of this generic command rail prevents a second
    // direct POST path that could bypass the required reason/step-up UX.
    .filter((action) => !["approve", "reject", "request-changes", "recuse", "accept-suggestion", "reject-suggestion"].includes(action.id))
    .filter((action) => action.id !== attachmentUpload?.actionId)
    .filter((action) => action.id !== attachmentRemoval?.actionId)
    .filter((action) => action.id !== "select-file")
    .filter((action) => !(screen.id === "RSP-003" && action.id === "save-draft"))
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
    void navigator.clipboard.writeText(
      `${screen.title}\n${window.location.href}`,
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
    window.sessionStorage.clear();
    window.localStorage.clear();
    window.location.assign("/auth/sign-in");
    return;
  }
  if (action.id === "view-compact") {
    document.documentElement.classList.toggle("compact-preview");
    return;
  }
  const search = document.querySelector<HTMLFormElement>('form[role="search"]');
  if (
    (action.id.includes("search") || action.id.includes("filter")) &&
    search
  ) {
    search.requestSubmit();
    return;
  }
  if (action.id === "open-evidence") {
    const destination = hrefFor(action);
    if (destination) window.location.assign(destination);
  }
}

function downloadData(action: ScreenViewModel["actions"][number]) {
  if (typeof document === "undefined") return;
  if (screen.id === "PUB-021" && action.id === "download-openapi") {
    const link = document.createElement("a");
    link.href = "/api/openapi.json";
    document.body.append(link);
    link.click();
    link.remove();
    return;
  }
  const encoded = Object.entries(runtime.data).find(
    ([operationId, value]) =>
      operationId.startsWith("download") &&
      isRecord(value) &&
      typeof value.binary === "string",
  )?.[1];
  if (isRecord(encoded) && typeof encoded.binary === "string") {
    const bytes = Uint8Array.from(atob(encoded.binary), (character) =>
      character.charCodeAt(0),
    );
    saveBlob(
      action,
      new Blob([bytes], { type: "application/json;charset=utf-8" }),
      "json",
    );
    return;
  }
  const data = preferredDownloadData(action.id);
  const csv = action.id.includes("csv");
  const content = csv ? csvText(data) : JSON.stringify(data, null, 2);
  const extension = csv ? "csv" : "json";
  const blob = new Blob([content], {
    type: csv ? "text/csv;charset=utf-8" : "application/json;charset=utf-8",
  });
  saveBlob(action, blob, extension);
}

function saveBlob(
  action: ScreenViewModel["actions"][number],
  blob: Blob,
  extension: string,
) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = `${screen.id.toLowerCase()}-${action.id}.${extension}`;
  document.body.append(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

function preferredDownloadData(actionId: string): unknown {
  const entries = Object.entries(runtime.data);
  const tokens = actionId.split("-").filter((part) => part !== "download");
  return (
    entries.find(([key]) =>
      tokens.some((token) => key.toLowerCase().includes(token.toLowerCase())),
    )?.[1] ??
    entries.find(([key]) =>
      ["reproducibility", "receipt", "request", "openapi", "contracts"].some(
        (token) => key.toLowerCase().includes(token),
      ),
    )?.[1] ??
    runtime.data
  );
}

function csvText(value: unknown): string {
  const rows = Array.isArray(value)
    ? value
    : isRecord(value) && Array.isArray(value.items)
      ? value.items
      : [value];
  const records = rows.filter(isRecord);
  const columns = [...new Set(records.flatMap((row) => Object.keys(row)))];
  const escapeCsvCell = (item: unknown) =>
    `"${(typeof item === "object" ? JSON.stringify(item) : String(item ?? "")).replaceAll('"', '""')}"`;
  return [
    columns.map(escapeCsvCell).join(","),
    ...records.map((row) =>
      columns.map((column) => escapeCsvCell(row[column])).join(","),
    ),
  ].join("\n");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
</script>

{#if visibleActions.length > 0 || attachmentUpload || attachmentRemoval}
  <section id="page-actions" class="command-panel" aria-labelledby="command-heading" data-component="GuidedFormSection" data-testid="screen-actions">
    <div class="section-content">
      <p class="component-kicker">다음 단계</p><h2 id="command-heading">화면 작업</h2>
      <div class="action-grid">
        {#if attachmentUpload}
          <form method="POST" action={`?/${attachmentUpload.actionId}`} enctype="multipart/form-data" data-action-id={attachmentUpload.actionId}>
            <h3>{attachmentUpload.label}</h3>
            <p>파일은 서버 경계를 통해 전송되며 체크섬과 크기가 일치한 경우에만 격리 저장소에서 검사를 시작합니다.</p>
            {#if runtime.csrfToken}<input type="hidden" name="csrfToken" value={runtime.csrfToken} />{/if}
            {#if runtime.idempotencyKeys?.[attachmentUpload.actionId]}<input type="hidden" name="idempotencyKey" value={runtime.idempotencyKeys[attachmentUpload.actionId]} />{/if}
            <label><span>첨부 파일 (필수, 최대 {Math.floor(attachmentUpload.maxBytes / 1_048_576)} MiB)</span><input type="file" name="attachment" accept={attachmentUpload.accept} required /></label>
            <button class="primary-button" type="submit">{attachmentUpload.label}</button>
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
              <form method="POST" action={`?/${attachmentRemoval.actionId}`} data-action-id={attachmentRemoval.actionId} data-attachment-id={item.id}>
                <h3>{item.filename}</h3>
                <p>
                  {item.mediaType ?? "파일"}
                  {#if item.sizeBytes !== undefined} · {Math.ceil(item.sizeBytes / 1024).toLocaleString()} KiB{/if}
                  {#if item.uploadStatus} · 업로드 {item.uploadStatus}{/if}
                  {#if item.scanStatus} · 검사 {item.scanStatus}{/if}
                </p>
                {#if runtime.csrfToken}<input type="hidden" name="csrfToken" value={runtime.csrfToken} />{/if}
                {#if runtime.idempotencyKeys?.[attachmentRemoval.actionId]}<input type="hidden" name="idempotencyKey" value={runtime.idempotencyKeys[attachmentRemoval.actionId]} />{/if}
                <input type="hidden" name="attachmentId" value={item.id} />
                <button class="secondary-button" type="submit">{attachmentRemoval.label}</button>
              </form>
            {/each}
          {/if}
        {/if}
        {#each visibleActions as action (action.id)}
          {#if operationId(action)}
            <form method="POST" action={`?/${action.id}`} data-action-id={action.id}>
              <h3>{action.label}</h3>
              {#if runtime.csrfToken}<input type="hidden" name="csrfToken" value={runtime.csrfToken} />{/if}
              {#if runtime.idempotencyKeys?.[action.id]}<input type="hidden" name="idempotencyKey" value={runtime.idempotencyKeys[action.id]} />{/if}
              {#each fieldsFor(action.id) as field (field.name)}
                {#if field.name === "abuseProof"}
                  <BotChallenge
                    config={runtime.botChallenge}
                    action={field.challengeAction ?? operationId(action) ?? "anonymousSubmission"}
                    onProof={(proof) => {
                      challengeReady[action.id] = proof.length > 0;
                    }}
                  />
                {:else}<label><span>{field.label && field.label !== field.name ? field.label : humanFieldLabel(field.name)}{field.required ? " (필수)" : ""}</span>
                  {#if field.readonly}<input type="hidden" name={field.name} value={field.value ?? ""} readonly /><output>{field.value === undefined ? "—" : String(field.value)}</output>
                  {:else if field.type === "boolean" && !field.required}<select name={field.name}>
                    <option value="" selected={field.value === undefined}>변경 안 함</option>
                    <option value="true" selected={field.value === true}>예</option>
                    <option value="false" selected={field.value === false}>아니오</option>
                  </select>
                  {:else if field.type === "boolean"}<input type="checkbox" name={field.name} value="true" checked={field.value === true} />
                  {:else if field.type === "json" && (field.name === "answers" || field.name.toLowerCase().includes("consent"))}<StructuredJsonField name={field.name} label={field.label && field.label !== field.name ? field.label : humanFieldLabel(field.name)} value={field.value} required={field.required} />
                  {:else if field.type === "json"}<textarea name={field.name} required={field.required} rows="4">{typeof field.value === "string" ? field.value : ""}</textarea>
                  {:else if field.options}<select name={field.name} required={field.required}>{#each field.options as option}<option value={option} selected={String(field.value ?? "") === option}>{option}</option>{/each}</select>
                  {:else}<input type={field.type} name={field.name} required={field.required} readonly={field.readonly} value={field.value ?? ""} />{/if}
                </label>{/if}
              {/each}
              <button class="primary-button" type="submit" disabled={Boolean(challengeField(action.id)) && !challengeReady[action.id]}>{action.label}</button>
            </form>
          {:else if interactionKind(action) === "DOWNLOAD"}
            <button class="secondary-button local-action" type="button" onclick={() => downloadData(action)} data-action-id={action.id}>{action.label}</button>
          {:else if interactionKind(action) === "COMMAND"}
            <button class="secondary-button local-action" type="button" onclick={() => runLocalCommand(action)} data-action-id={action.id}>{action.label}</button>
          {:else if hrefFor(action)}
            <a class="secondary-button local-action" href={hrefFor(action)} target={interactionKind(action) === "EXTERNAL_LINK" ? "_blank" : undefined} rel={interactionKind(action) === "EXTERNAL_LINK" ? "noreferrer" : undefined} data-action-id={action.id}>{action.label}</a>
          {/if}
        {/each}
      </div>
    </div>
  </section>
{/if}
