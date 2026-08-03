<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import { formFieldId, humanFieldLabel } from "../../screen-contract";
import { toRsp005ViewModel } from "../../view-models/rsp-005";
import StructuredJsonField from "../StructuredJsonField.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, screen, runtime }: ScreenSectionProps = $props();
const fieldCount = $derived(
  Object.values(runtime.forms).reduce((sum, fields) => sum + fields.length, 0),
);
const fieldGroups = $derived(
  Object.entries(runtime.forms).map(([actionId, fields]) => ({
    actionId,
    fields,
  })),
);
const showGuide = $derived(
  screen.sections.find(
    (candidate) => candidate.component === "GuidedFormSection",
  )?.id === section.id,
);
const draft = $derived(record(runtime.formData?.responseDraft));
const submitted = $derived(record(runtime.formData?.submitted));
const saveAction = $derived(
  screen.actions.find((action) => action.id === "save-draft"),
);
const saveFields = $derived(runtime.forms["save-draft"] ?? []);
const submitAction = $derived(
  screen.id === "RSP-005"
    ? screen.actions.find((action) => action.id === "submit")
    : undefined,
);
const submitFields = $derived(runtime.forms.submit ?? []);
const hasValidationError = $derived(
  ["validation-error", "error", "conflict"].includes(runtime.state),
);
const invalidField = (
  actionId: string,
  field: { name: string; label: string; readonly?: boolean },
): boolean => {
  if (!hasValidationError || field.readonly) return false;
  const haystack = runtime.errors.join(" ").toLowerCase();
  if (
    [field.name, field.label].some(
      (token) => token && haystack.includes(token.toLowerCase()),
    )
  )
    return true;
  return (
    (runtime.forms[actionId] ?? []).find((candidate) => !candidate.readonly)
      ?.name === field.name
  );
};
const isAnswerScreen = $derived(
  screen.id === "RSP-003" && section.id === "questions",
);
const isReviewSubmitScreen = $derived(
  screen.id === "RSP-005" && section.id === "consequence",
);
const preview = $derived(record(runtime.formData?.submissionPreview));
const reviewVm = $derived(
  screen.id === "RSP-005"
    ? toRsp005ViewModel({
        getResponseSubmissionPreview: runtime.formData?.submissionPreview,
      })
    : null,
);
const previewConsent = $derived(record(preview?.publicationConsent));
const submittedAnswers = $derived(
  typeof submitted?.answers === "string"
    ? (() => {
        try {
          return JSON.parse(submitted.answers);
        } catch {
          return [];
        }
      })()
    : submitted?.answers,
);
const submittedConsent = $derived(
  typeof submitted?.publicationConsent === "string"
    ? (() => {
        try {
          return JSON.parse(submitted.publicationConsent);
        } catch {
          return {};
        }
      })()
    : submitted?.publicationConsent,
);
const answers = $derived(submittedAnswers ?? draft?.answers ?? []);
const consent = $derived(submittedConsent ?? draft?.publicationConsent ?? {});
const attachmentOptions = $derived(
  Array.isArray(draft?.attachments)
    ? draft.attachments.flatMap((item) => {
        const row = record(item);
        const id = typeof row?.id === "string" ? row.id : null;
        if (!id) return [];
        const filename =
          typeof row?.filename === "string" ? row.filename : null;
        return [filename === null ? { id } : { id, filename }];
      })
    : [],
);
function record(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}
function formAction(actionId: string): string {
  const search = runtime.search ?? "";
  const query = search
    .replace(/^\?/, "")
    .split("&")
    .filter((part) => part && !part.startsWith("/") && !part.startsWith("%2F"))
    .join("&");
  return query ? `?/${actionId}&${query}` : `?/${actionId}`;
}
type AutoCompleteToken =
  | "email"
  | "tel"
  | "given-name"
  | "family-name"
  | "name"
  | "language"
  | "off";
function autocompleteFor(name: string): AutoCompleteToken {
  const normalized = name.toLowerCase();
  if (normalized.includes("email")) return "email";
  if (normalized.includes("phone") || normalized.includes("tel")) return "tel";
  if (normalized.includes("locale") || normalized.includes("language"))
    return "language";
  if (normalized === "name" || normalized.endsWith("name")) return "name";
  return "off";
}
</script>

<SectionHeading {section} kicker="단계별 입력" />
<div class="guided-form-intro">
  {#if showGuide}<p>필수 입력과 검토 후 제출하며, 세션·권한은 단계마다 서버가 확인합니다.</p>{/if}
  {#if screen.id === "RSP-005" && (section.id === "consent" || section.id === "authority" || section.id === "consequence")}
    {#if section.id === "consent"}<p>본문 공개: {previewConsent?.bodyConsent === true ? "동의" : "미동의"}</p><p>민감정보 가림 확인: {previewConsent?.redactionAcknowledged === true ? "확인" : "미확인"} · 첨부 공개 {Array.isArray(previewConsent?.attachmentConsents) ? previewConsent.attachmentConsents.filter((item) => record(item)?.mayPublish === true).length : 0}개</p>
    {:else if section.id === "authority"}<p>제출 권한과 세션 범위는 서버가 preview 시점에 확인합니다. 권한이 확인되지 않으면 제출 버튼을 사용할 수 없습니다.</p>
    {:else}<p>제출 후에는 immutable receipt와 submission digest가 발급되며, 수정은 보충자료 경로에서 새 영수증으로 남습니다.</p>{/if}
  {:else if isAnswerScreen && saveAction}
    <form id={`action-${saveAction.id}`} method="POST" action={formAction(saveAction.id)} class="guided-response-form answer-consent-form" data-action-id={saveAction.id}>
      {#if runtime.idempotencyKeys?.[saveAction.id]}<input type="hidden" name="idempotencyKey" value={runtime.idempotencyKeys[saveAction.id]} />{/if}
      {#if runtime.csrfToken}<input type="hidden" name="csrfToken" value={runtime.csrfToken} />{/if}
      <p id={`action-${saveAction.id}-field-help`} class="field-help" class:field-error={hasValidationError} aria-live="polite">{hasValidationError ? "입력값을 확인한 뒤 다시 시도하세요." : "필수 입력은 저장 전에 서버에서 다시 확인됩니다."}</p>
      {#each saveFields as field (field.name)}
        {#if field.name === "answers"}<StructuredJsonField idPrefix={formFieldId(screen.id, saveAction.id, field.name)} name="answers" label="질문별 답변" value={answers} attachmentOptions={attachmentOptions} required={field.required} invalid={invalidField(saveAction.id, field)} />
        {:else if field.name === "publicationConsent"}<StructuredJsonField idPrefix={formFieldId(screen.id, saveAction.id, field.name)} name="publicationConsent" label="공개 동의" value={consent} attachmentOptions={attachmentOptions} required={field.required} invalid={invalidField(saveAction.id, field)} />
        {:else if field.readonly}<input type="hidden" name={field.name} value={field.value ?? ""} />
        {:else if field.name !== "answers" && field.name !== "publicationConsent"}<label for={formFieldId(screen.id, saveAction.id, field.name)}><span>{field.label && field.label !== field.name ? field.label : humanFieldLabel(field.name)}{field.required ? " (필수)" : ""}</span><input id={formFieldId(screen.id, saveAction.id, field.name)} name={field.name} type={field.type} autocomplete={autocompleteFor(field.name)} value={field.value ?? ""} required={field.required} aria-invalid={invalidField(saveAction.id, field) ? "true" : undefined} aria-describedby={`action-${saveAction.id}-field-help`} /></label>{/if}
      {/each}
      <button class="primary-button" type="submit">{saveAction.label}</button>
    </form>
  {:else if isReviewSubmitScreen && submitAction}
    <form id={`action-${submitAction.id}`} method="POST" action={formAction(submitAction.id)} class="guided-response-form" data-action-id={submitAction.id}>
      {#if runtime.idempotencyKeys?.[submitAction.id]}<input type="hidden" name="idempotencyKey" value={runtime.idempotencyKeys[submitAction.id]} />{/if}
      {#if runtime.csrfToken}<input type="hidden" name="csrfToken" value={runtime.csrfToken} />{/if}
      <p id={`action-${submitAction.id}-field-help`} class="field-help" class:field-error={hasValidationError} aria-live="polite">{hasValidationError ? "입력값을 확인한 뒤 다시 시도하세요." : "제출 전 필수 항목과 권한을 다시 확인합니다."}</p>
      {#each submitFields as field (field.name)}
        {#if field.name === "publicationConsent"}<StructuredJsonField idPrefix={formFieldId(screen.id, submitAction.id, field.name)} name="publicationConsent" label="최종 공개 동의" value={previewConsent ?? consent} attachmentOptions={attachmentOptions} required={field.required} invalid={invalidField(submitAction.id, field)} />
        {:else if field.name === "attestation"}<label class="attestation-field" for={formFieldId(screen.id, submitAction.id, field.name)}><input id={formFieldId(screen.id, submitAction.id, field.name)} name="attestation" type="checkbox" value="true" required={field.required} aria-invalid={invalidField(submitAction.id, field) ? "true" : undefined} aria-describedby={`action-${submitAction.id}-field-help`} /><span>위 답변과 첨부가 사실에 맞고, 제출 후 변경은 새 영수증으로 남는다는 점을 확인했습니다.</span></label>
        {:else if field.readonly}<input type="hidden" name={field.name} value={field.value ?? ""} />
        {:else}<input type="hidden" name={field.name} value={field.value ?? ""} />{/if}
      {/each}
      <p class="field-help">제출하면 서버가 첨부 상태·version·권한을 다시 확인하고 immutable receipt를 발급합니다.</p>
      <button class="primary-button" type="submit" disabled={reviewVm?.consequence.blocked === true} aria-disabled={reviewVm?.consequence.blocked === true}>
        {reviewVm?.consequence.blocked ? "차단 사유를 해결한 뒤 제출" : submitAction.label}
      </button>
    </form>
  {:else}
    <p>입력 필드: <strong>{fieldCount}</strong>개</p>
    {#if fieldGroups.length > 0}<dl class="guided-field-summary" aria-label="입력 항목 안내">{#each fieldGroups as group (group.actionId)}<div><dt>{group.actionId}</dt><dd>{group.fields.map((field) => `${field.label && field.label !== field.name ? field.label : field.name}${field.required ? " · 필수" : ""}`).join(" · ")}</dd></div>{/each}</dl>
    {:else}<p role="status">현재 세션에서 입력할 항목이 없습니다.</p>{/if}
  {/if}
</div>

<style>
  .guided-form-intro {
    display: grid;
    gap: 0.5rem;
    padding-block: 0.625rem 0;
    border-top: 1px solid var(--paper-200);
  }
  .guided-form-intro > p,
  .field-help {
    margin: 0;
    color: var(--ink-700);
    font-size: 0.8125rem;
    line-height: 1.5;
  }
  .guided-response-form {
    display: grid;
    gap: 0.625rem;
    padding-top: 0.625rem;
    border-top: 1px solid var(--paper-200);
  }
  .answer-consent-form {
    grid-template-columns: repeat(
      auto-fit,
      minmax(min(100%, 22rem), 1fr)
    );
    column-gap: 0.875rem;
  }
  .answer-consent-form > .field-help,
  .answer-consent-form > button {
    grid-column: 1 / -1;
  }
  .guided-response-form > label:not(.attestation-field) {
    display: grid;
    gap: 0.25rem;
    color: var(--ink-900);
    font-size: 0.8125rem;
    font-weight: 650;
  }
  .attestation-field {
    display: grid;
    grid-template-columns: 1.25rem minmax(0, 1fr);
    gap: 0.5rem;
    align-items: start;
    padding-block: 0.5rem;
    border-top: 1px solid var(--paper-200);
    color: var(--ink-900);
    font-size: 0.8125rem;
    line-height: 1.5;
  }
  .attestation-field input {
    margin-top: 0.125rem;
  }
  .field-help {
    font-size: 0.75rem;
  }
  .field-error {
    color: var(--red-700);
  }
  .guided-response-form > button {
    justify-self: start;
  }
  .guided-field-summary {
    display: grid;
    grid-template-columns: repeat(
      auto-fit,
      minmax(min(100%, 24rem), 1fr)
    );
    column-gap: 1rem;
    margin: 0;
  }
  .guided-field-summary div {
    display: grid;
    grid-template-columns: minmax(8rem, 0.35fr) minmax(0, 1fr);
    gap: 0.75rem;
    padding-block: 0.375rem;
    border-top: 1px solid var(--paper-200);
  }
  .guided-field-summary dt {
    color: var(--ink-500);
    font-size: 0.75rem;
    font-weight: 650;
  }
  .guided-field-summary dd {
    margin: 0;
    font-size: 0.875rem;
    overflow-wrap: anywhere;
  }
  @media (max-width: 620px) {
    .answer-consent-form,
    .guided-field-summary {
      grid-template-columns: minmax(0, 1fr);
    }
    .guided-response-form > button,
    .attestation-field {
      min-height: 44px;
    }
    .guided-field-summary div {
      grid-template-columns: minmax(0, 1fr);
      gap: 0.25rem;
    }
  }
  @media (forced-colors: active) {
    .guided-form-intro,
    .guided-response-form,
    .attestation-field,
    .guided-field-summary div {
      border-color: CanvasText;
    }
  }
</style>
