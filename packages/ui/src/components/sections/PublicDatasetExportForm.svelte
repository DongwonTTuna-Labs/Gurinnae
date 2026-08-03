<script lang="ts">
import type { BotChallengeRuntime, ScreenField } from "../../index";
import { projectionScalarText } from "../../projection-value";
import {
  datasetExportFormContract,
  hiddenFieldValue,
  namedFormAction,
  type PublicDatasetRecord,
  publicDatasetCards,
} from "../../public-form-presentation";
import BotChallenge from "../BotChallenge.svelte";

let {
  fields,
  datasets,
  actionId = "download-dataset",
  actionLabel = "데이터 다운로드",
  search = "",
  csrfToken,
  idempotencyKey,
  botChallenge,
  hasValidationError = false,
}: {
  fields: readonly ScreenField[];
  datasets: readonly PublicDatasetRecord[];
  actionId?: string;
  actionLabel?: string;
  search?: string;
  csrfToken?: string | undefined;
  idempotencyKey?: string | undefined;
  botChallenge?: BotChallengeRuntime | undefined;
  hasValidationError?: boolean;
} = $props();

const contract = $derived(datasetExportFormContract(fields));
const cards = $derived(publicDatasetCards(datasets));
let selectedId = $state("");
let selectedFormat = $state("");
let challengeReady = $state(false);
let challengeProof = $state("");

function appendChallengeProof(event: FormDataEvent) {
  if (challengeProof) event.formData.append("abuseProof", challengeProof);
}
</script>

{#if cards.length === 0}
  <p class="dataset-empty" role="status">현재 내려받을 수 있는 데이터셋이 없습니다.</p>
{:else}
  <form
    id={`action-${actionId}`}
    class="dataset-export-form"
    method="POST"
    action={namedFormAction(actionId, search)}
    data-action-id={actionId}
    data-component="PublicDatasetExportForm"
    onformdata={appendChallengeProof}
  >
    {#if csrfToken}<input type="hidden" name="csrfToken" value={csrfToken} />{/if}
    {#if idempotencyKey}<input type="hidden" name="idempotencyKey" value={idempotencyKey} />{/if}
    <input type="hidden" name="filters" value={hiddenFieldValue(contract.filters)} />
    <input type="hidden" name="expiresInSeconds" value={hiddenFieldValue(contract.expiresInSeconds)} />

    <p
      id={`action-${actionId}-field-help`}
      class:field-error={hasValidationError}
      class="field-help"
      aria-live="polite"
    >{hasValidationError ? "입력값을 확인한 뒤 다시 시도하세요." : "데이터셋과 파일 형식을 확인한 뒤 내려받기를 요청합니다."}</p>

    <fieldset aria-describedby={`action-${actionId}-field-help`}>
      <legend>데이터셋 선택 (필수)</legend>
      <div class="dataset-options">
        {#each cards as card (card.id)}
          <label class:selected={selectedId === card.id} class="dataset-option">
            <input
              type="radio"
              name="datasetId"
              value={card.id}
              bind:group={selectedId}
              required
            />
            <span class="dataset-title">{card.title}</span>
            <span class="dataset-description">{card.description}</span>
            <span class="dataset-meta">
              제공 형식 {card.format} · {card.license} · {projectionScalarText("updatedAt", card.updatedAt) ?? card.updatedAt}
            </span>
            <span class="dataset-notice">{card.redistributionNotice}</span>
          </label>
        {/each}
      </div>
    </fieldset>

    <label class="format-field" for={`action-${actionId}-format`}>
      <span>파일 형식 (필수)</span>
      <select
        id={`action-${actionId}-format`}
        name="format"
        bind:value={selectedFormat}
        required
        aria-describedby={`action-${actionId}-field-help`}
      >
        <option value="" disabled>형식 선택</option>
        {#each contract.format.options ?? [] as option}
          <option value={option}>{option}</option>
        {/each}
      </select>
    </label>

    <label class="email-field" for={`action-${actionId}-email`}>
      <span>완료 알림 이메일{contract.email.required ? " (필수)" : " (선택)"}</span>
      <input
        id={`action-${actionId}-email`}
        type="email"
        name="email"
        autocomplete="email"
        value={contract.email.value ?? ""}
        required={contract.email.required}
        aria-describedby={`action-${actionId}-field-help`}
      />
    </label>

    <BotChallenge
      config={botChallenge}
      action={contract.challengeAction}
      onProof={(proof) => {
        challengeProof = proof;
        challengeReady = proof.length > 0;
      }}
    />
    <button class="primary-button" type="submit" disabled={!challengeReady}>
      {actionLabel}
    </button>
  </form>
{/if}

<style>
  .dataset-export-form {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(14rem, 0.45fr);
    gap: 0.75rem 1rem;
    padding-block: 0.625rem;
    border-top: 1px solid var(--paper-200);
  }
  .field-help,
  .dataset-empty {
    grid-column: 1 / -1;
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
  .format-field > span,
  .email-field > span {
    margin-bottom: 0.375rem;
    color: var(--ink-900);
    font-size: 0.8125rem;
    font-weight: 650;
  }
  .dataset-options {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 16rem), 1fr));
    border-top: 1px solid var(--paper-200);
  }
  .dataset-option {
    display: grid;
    grid-template-columns: auto minmax(0, 1fr);
    gap: 0.2rem 0.5rem;
    align-content: start;
    min-width: 0;
    padding: 0.625rem;
    border-bottom: 1px solid var(--paper-200);
    cursor: pointer;
  }
  .dataset-option.selected {
    background: var(--paper-100);
  }
  .dataset-option input {
    grid-row: 1 / 5;
    margin: 0.15rem 0 0;
  }
  .dataset-title {
    color: var(--ink-900);
    font-size: 0.9375rem;
    font-weight: 700;
  }
  .dataset-description,
  .dataset-meta,
  .dataset-notice {
    color: var(--ink-700);
    font-size: 0.75rem;
    line-height: 1.45;
  }
  .format-field,
  .email-field {
    display: grid;
    align-content: start;
    gap: 0.25rem;
    min-width: 0;
  }
  .format-field select,
  .email-field input {
    min-width: 0;
  }
  button {
    grid-column: 1 / -1;
    min-height: 44px;
    justify-self: start;
  }
  @media (max-width: 760px) {
    .dataset-export-form {
      grid-template-columns: minmax(0, 1fr);
    }
    .field-help,
    button {
      grid-column: 1;
    }
    .dataset-option {
      min-height: 44px;
    }
  }
  @media (forced-colors: active) {
    .dataset-export-form,
    .dataset-options,
    .dataset-option {
      border-color: CanvasText;
    }
  }
</style>
