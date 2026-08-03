<script lang="ts">
import { untrack } from "svelte";
import type { BotChallengeRuntime, ScreenField } from "../../index";
import {
  correctionRequestFormContract,
  hiddenFieldValue,
  namedFormAction,
  requestedChangesJson,
  requestedChangesText,
} from "../../public-form-presentation";
import BotChallenge from "../BotChallenge.svelte";

let {
  fields,
  actionId = "save-draft",
  actionLabel = "임시 저장",
  search = "",
  csrfToken,
  idempotencyKey,
  botChallenge,
  hasValidationError = false,
}: {
  fields: readonly ScreenField[];
  actionId?: string;
  actionLabel?: string;
  search?: string;
  csrfToken?: string | undefined;
  idempotencyKey?: string | undefined;
  botChallenge?: BotChallengeRuntime | undefined;
  hasValidationError?: boolean;
} = $props();

const contract = $derived(correctionRequestFormContract(fields));
let changes = $state(
  untrack(() => requestedChangesText(contract.requestedChanges.value)),
);
let challengeReady = $state(
  untrack(() => contract.challengeAction === undefined),
);
let challengeProof = $state("");

function appendChallengeProof(event: FormDataEvent) {
  if (challengeProof) event.formData.append("abuseProof", challengeProof);
}

type BoundField = ScreenField & {
  readonly: true;
  value: string | number | boolean;
};

function isBound(field: ScreenField): field is BoundField {
  return field?.readonly === true && field.value !== undefined;
}
</script>

<form
  id={`action-${actionId}`}
  class="correction-request-form"
  method="POST"
  action={namedFormAction(actionId, search)}
  data-action-id={actionId}
  data-component="PublicCorrectionRequestForm"
  onformdata={appendChallengeProof}
>
  {#if csrfToken}<input type="hidden" name="csrfToken" value={csrfToken} />{/if}
  {#if idempotencyKey}<input type="hidden" name="idempotencyKey" value={idempotencyKey} />{/if}
  {#if contract.locale}<input type="hidden" name="locale" value={hiddenFieldValue(contract.locale)} />{/if}
  <input type="hidden" name="expectedVersion" value={hiddenFieldValue(contract.expectedVersion)} />
  <input type="hidden" name="requestedChanges" value={requestedChangesJson(changes)} />

  <p
    id={`action-${actionId}-field-help`}
    class:field-error={hasValidationError}
    class="field-help"
    aria-live="polite"
  >{hasValidationError ? "입력값을 확인한 뒤 다시 시도하세요." : "사건과 공개 개정본을 확인한 뒤 변경 요청을 항목별로 입력합니다."}</p>

  {#if contract.caseSlug || contract.publicationRevision}
    <fieldset class="target-fields" aria-describedby={`action-${actionId}-field-help`}>
      <legend>정정 대상</legend>
      {#if contract.caseSlug}
        {#if isBound(contract.caseSlug)}
          <input type="hidden" name="caseSlug" value={hiddenFieldValue(contract.caseSlug)} />
          <div><span>사건</span><output>{contract.caseSlug.value}</output></div>
        {:else}
          <label for={`action-${actionId}-caseSlug`}>
            <span>사건 경로명{contract.caseSlug.required ? " (필수)" : ""}</span>
            <input
              id={`action-${actionId}-caseSlug`}
              type="text"
              name="caseSlug"
              value={contract.caseSlug.value ?? ""}
              required={contract.caseSlug.required}
              aria-describedby={`action-${actionId}-field-help`}
            />
          </label>
        {/if}
      {/if}
      {#if contract.publicationRevision}
        {#if isBound(contract.publicationRevision)}
          <input type="hidden" name="publicationRevision" value={hiddenFieldValue(contract.publicationRevision)} />
          <div><span>공개 개정본</span><output>{contract.publicationRevision.value}</output></div>
        {:else}
          <label for={`action-${actionId}-publicationRevision`}>
            <span>공개 개정본{contract.publicationRevision.required ? " (필수)" : ""}</span>
            <input
              id={`action-${actionId}-publicationRevision`}
              type="number"
              name="publicationRevision"
              value={contract.publicationRevision.value ?? ""}
              required={contract.publicationRevision.required}
              step="1"
              aria-describedby={`action-${actionId}-field-help`}
            />
          </label>
        {/if}
      {/if}
    </fieldset>
  {/if}

  <div class="request-fields">
    <label for={`action-${actionId}-requesterType`}>
      <span>요청자 유형 (필수)</span>
      <input
        id={`action-${actionId}-requesterType`}
        type="text"
        name="requesterType"
        value={contract.requesterType.value ?? ""}
        required
        aria-describedby={`action-${actionId}-field-help`}
      />
    </label>
    <label for={`action-${actionId}-contactEmail`}>
      <span>연락 이메일 (필수)</span>
      <input
        id={`action-${actionId}-contactEmail`}
        type="email"
        name="contactEmail"
        autocomplete="email"
        value={contract.contactEmail.value ?? ""}
        required
        aria-describedby={`action-${actionId}-field-help`}
      />
    </label>
    <label class="wide-field" for={`action-${actionId}-summary`}>
      <span>요청 요약 (필수)</span>
      <input
        id={`action-${actionId}-summary`}
        type="text"
        name="summary"
        value={contract.summary.value ?? ""}
        required
        aria-describedby={`action-${actionId}-field-help`}
      />
    </label>
    <label class="wide-field" for={`action-${actionId}-requestedChangesInput`}>
      <span>요청 변경 내역 (필수, 한 줄에 한 항목)</span>
      <textarea
        id={`action-${actionId}-requestedChangesInput`}
        name="requestedChangesInput"
        bind:value={changes}
        rows="4"
        required
        aria-describedby={`action-${actionId}-field-help`}
      ></textarea>
    </label>
    <label class="wide-field" for={`action-${actionId}-evidenceDescription`}>
      <span>근거 설명{contract.evidenceDescription.required ? " (필수)" : " (선택)"}</span>
      <textarea
        id={`action-${actionId}-evidenceDescription`}
        name="evidenceDescription"
        rows="3"
        required={contract.evidenceDescription.required}
        aria-describedby={`action-${actionId}-field-help`}
      >{contract.evidenceDescription.value ?? ""}</textarea>
    </label>
  </div>

  {#if contract.challengeAction}
    <BotChallenge
      config={botChallenge}
      action={contract.challengeAction}
      onProof={(proof) => {
        challengeProof = proof;
        challengeReady = proof.length > 0;
      }}
    />
  {/if}
  <button class="primary-button" type="submit" disabled={!challengeReady}>
    {actionLabel}
  </button>
</form>

<style>
  .correction-request-form {
    display: grid;
    gap: 0.75rem;
    padding-block: 0.625rem;
    border-top: 1px solid var(--paper-200);
  }
  .field-help {
    margin: 0;
    color: var(--ink-700);
    font-size: 0.8125rem;
    line-height: 1.5;
  }
  .field-error {
    color: var(--red-700);
  }
  fieldset {
    min-width: 0;
    margin: 0;
    padding: 0;
    border: 0;
  }
  legend,
  label > span,
  .target-fields div > span {
    color: var(--ink-900);
    font-size: 0.8125rem;
    font-weight: 650;
  }
  .target-fields {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 14rem), 1fr));
    gap: 0.5rem 1rem;
    padding-block: 0.5rem;
    border-block: 1px solid var(--paper-200);
  }
  .target-fields legend {
    padding-right: 0.5rem;
  }
  .target-fields div,
  .target-fields label,
  .request-fields label {
    display: grid;
    gap: 0.25rem;
    min-width: 0;
  }
  .target-fields output {
    color: var(--ink-700);
    font-size: 0.875rem;
  }
  .request-fields {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 0.625rem 1rem;
  }
  .wide-field {
    grid-column: 1 / -1;
  }
  input,
  textarea {
    min-width: 0;
  }
  textarea {
    resize: vertical;
  }
  button {
    min-height: 44px;
    justify-self: start;
  }
  @media (max-width: 620px) {
    .request-fields {
      grid-template-columns: minmax(0, 1fr);
    }
    .wide-field {
      grid-column: 1;
    }
  }
  @media (forced-colors: active) {
    .correction-request-form,
    .target-fields {
      border-color: CanvasText;
    }
  }
</style>
