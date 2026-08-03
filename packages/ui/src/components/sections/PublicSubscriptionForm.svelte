<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import { formFieldId } from "../../screen-contract";
import {
  needsScopeRef,
  publicSubscriptionForm,
  scopeReferenceLabel,
  scopeReferencePattern,
  subscriptionFrequencyLabel,
  subscriptionScopeLabel,
} from "../../subscription-form";
import BotChallenge from "../BotChallenge.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, screen, runtime }: ScreenSectionProps = $props();
const result = $derived(publicSubscriptionForm(screen, runtime));
const model = $derived(result.ready ? result.model : undefined);
let scopeType = $derived(
  model?.fixedScopeType ??
    (typeof model?.scopeType.value === "string" ? model.scopeType.value : ""),
);
let frequency = $derived(
  typeof model?.frequency.value === "string" ? model.frequency.value : "",
);
let email = $state("");
let challengeReady = $state(false);
let challengeProof = $state("");
const hasValidationError = $derived(
  ["validation-error", "error", "conflict"].includes(runtime.state),
);
const fieldHelpId = $derived(
  model
    ? `action-${model.actionId}-field-help`
    : "subscription-form-field-help",
);
const queryNeedsContext = $derived(
  Boolean(model && !model.fixedScopeType && scopeType === "QUERY"),
);
const selectedScopeLabel = $derived(
  subscriptionScopeLabel(model?.fixedScopeType ?? scopeType),
);
const selectedFrequencyLabel = $derived(subscriptionFrequencyLabel(frequency));

function appendChallengeProof(event: FormDataEvent) {
  if (challengeProof) event.formData.append("abuseProof", challengeProof);
}
</script>

<SectionHeading {section} kicker="구독 확인" />
{#if !model}
  <p class="form-unavailable" role="status">
    구독 입력 구성을 확인하지 못했습니다. 이전 화면에서 대상을 다시 선택해 주세요.
  </p>
{:else}
  <form
    id={`action-${model.actionId}`}
    class="subscription-form"
    method="POST"
    action={model.formAction}
    data-testid="public-subscription-form"
    onformdata={appendChallengeProof}
  >
    {#if runtime.csrfToken}
      <input type="hidden" name="csrfToken" value={runtime.csrfToken} />
    {/if}
    <input
      type="hidden"
      name="idempotencyKey"
      value={model.idempotencyKey}
    />
    {#each model.fixedFields as field (field.name)}
      <input type="hidden" name={field.name} value={field.value ?? ""} />
    {/each}

    <p
      id={fieldHelpId}
      class="field-help"
      class:field-error={hasValidationError}
      aria-live="polite"
    >
      {hasValidationError
        ? "입력값을 확인한 뒤 다시 시도하세요."
        : "이메일 확인 전에는 구독이 시작되지 않으며, 확인 뒤 관리 링크에서 해지할 수 있습니다."}
    </p>

    <div class="subscription-fields">
      <label for={formFieldId(screen.id, model.actionId, model.email.name)}>
        <span>이메일 주소 (필수)</span>
        <input
          id={formFieldId(screen.id, model.actionId, model.email.name)}
          name={model.email.name}
          type="email"
          autocomplete="email"
          required
          bind:value={email}
          aria-invalid={hasValidationError ? "true" : undefined}
          aria-describedby={fieldHelpId}
        />
      </label>

      {#if model.fixedScopeType}
        <div class="fixed-value" data-field="scopeType">
          <span>구독 대상</span>
          <strong>
            {selectedScopeLabel}
            {model.fixedScopeType === "QUERY" ? " · 현재 검색 조건" : ""}
          </strong>
        </div>
      {:else}
        <label
          for={formFieldId(screen.id, model.actionId, model.scopeType.name)}
        >
          <span>구독 대상 (필수)</span>
          <select
            id={formFieldId(screen.id, model.actionId, model.scopeType.name)}
            name={model.scopeType.name}
            bind:value={scopeType}
            required
            aria-invalid={hasValidationError ? "true" : undefined}
            aria-describedby={fieldHelpId}
          >
            <option value="">대상 선택</option>
            {#each model.scopeType.options ?? [] as option}
              <option value={option}>{subscriptionScopeLabel(option)}</option>
            {/each}
          </select>
        </label>

        {#if needsScopeRef(scopeType)}
          <label
            for={formFieldId(screen.id, model.actionId, model.scopeRef.name)}
          >
            <span>{scopeReferenceLabel(scopeType)} (필수)</span>
            <input
              id={formFieldId(screen.id, model.actionId, model.scopeRef.name)}
              name={model.scopeRef.name}
              type="text"
              autocomplete="off"
              required
              value={model.scopeRef.value ?? ""}
              inputmode={scopeType === "REGION" ? "numeric" : undefined}
              pattern={scopeReferencePattern(scopeType)}
              maxlength={scopeType === "REGION" ? 5 : undefined}
              aria-invalid={hasValidationError ? "true" : undefined}
              aria-describedby={fieldHelpId}
            />
          </label>
        {/if}
      {/if}

      <label for={formFieldId(screen.id, model.actionId, model.frequency.name)}>
        <span>알림 빈도 (필수)</span>
        <select
          id={formFieldId(screen.id, model.actionId, model.frequency.name)}
          name={model.frequency.name}
          bind:value={frequency}
          required
          aria-invalid={hasValidationError ? "true" : undefined}
          aria-describedby={fieldHelpId}
        >
          <option value="">빈도 선택</option>
          {#each model.frequency.options ?? [] as option}
            <option value={option}>{subscriptionFrequencyLabel(option)}</option>
          {/each}
        </select>
      </label>
    </div>

    {#if queryNeedsContext}
      <p class="context-guidance" role="status">
        검색 조건 구독은 검색 결과 화면의 ‘이 조건 구독’ 링크에서 시작해 주세요.
      </p>
    {/if}

    <dl class="subscription-summary" aria-label="구독 선택 확인">
      <div>
        <dt>대상</dt>
        <dd>{selectedScopeLabel ?? "선택 전"}</dd>
      </div>
      <div>
        <dt>빈도</dt>
        <dd>{selectedFrequencyLabel ?? "선택 전"}</dd>
      </div>
    </dl>

    <label
      class="consent-field"
      for={formFieldId(screen.id, model.actionId, model.consent.name)}
    >
      <input
        id={formFieldId(screen.id, model.actionId, model.consent.name)}
        name={model.consent.name}
        type="checkbox"
        value="true"
        required
        aria-invalid={hasValidationError ? "true" : undefined}
        aria-describedby={fieldHelpId}
      />
      <span>선택한 범위의 공개 업데이트를 이 이메일로 받는 데 동의합니다.</span>
    </label>

    <BotChallenge
      config={runtime.botChallenge}
      action={model.abuseProof.challengeAction ?? "createSubscription"}
      onProof={(proof) => {
        challengeReady = proof.length > 0;
        challengeProof = proof;
      }}
    />

    <button
      class="primary-button"
      type="submit"
      data-action-id={model.actionId}
      data-testid="pub_029__action__request_verification"
      disabled={!challengeReady || queryNeedsContext}
      aria-disabled={!challengeReady || queryNeedsContext}
    >
      {model.actionLabel}
    </button>
  </form>
{/if}

<style>
  .subscription-form {
    display: grid;
    gap: 0.625rem;
    padding-top: 0.625rem;
    border-top: 1px solid var(--paper-200);
  }

  .field-help,
  .context-guidance,
  .form-unavailable {
    margin: 0;
    color: var(--ink-700);
    font-size: 0.8125rem;
    line-height: 1.5;
  }

  .field-error,
  .form-unavailable {
    color: var(--red-700);
  }

  .subscription-fields {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 14rem), 1fr));
    gap: 0.5rem 0.75rem;
  }

  .subscription-fields > label,
  .fixed-value {
    display: grid;
    gap: 0.25rem;
    min-width: 0;
    color: var(--ink-900);
    font-size: 0.8125rem;
    font-weight: 650;
  }

  .subscription-fields input,
  .subscription-fields select {
    width: 100%;
    min-height: 44px;
  }

  .fixed-value {
    align-content: start;
  }

  .fixed-value strong {
    min-height: 44px;
    padding: 0.625rem 0.75rem;
    border: 1px solid var(--paper-200);
    background: var(--paper-50);
    font-weight: 550;
    overflow-wrap: anywhere;
  }

  .context-guidance {
    padding: 0.5rem 0.625rem;
    border-inline-start: 3px solid var(--blue-500);
    background: var(--blue-50);
  }

  .subscription-summary {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    margin: 0;
    border-block: 1px solid var(--paper-200);
  }

  .subscription-summary > div {
    display: grid;
    grid-template-columns: 4rem minmax(0, 1fr);
    gap: 0.5rem;
    padding: 0.375rem 0.5rem;
  }

  .subscription-summary dt {
    color: var(--ink-500);
    font-size: 0.75rem;
    font-weight: 650;
  }

  .subscription-summary dd {
    margin: 0;
    color: var(--ink-900);
    font-size: 0.8125rem;
    font-weight: 650;
  }

  .consent-field {
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

  .consent-field input {
    margin-top: 0.125rem;
  }

  .subscription-form > button {
    min-height: 44px;
    justify-self: start;
  }

  @media (max-width: 620px) {
    .subscription-summary {
      grid-template-columns: minmax(0, 1fr);
    }
  }

  @media (forced-colors: active) {
    .context-guidance,
    .fixed-value strong,
    .subscription-summary,
    .consent-field {
      border-color: CanvasText;
    }
  }
</style>
