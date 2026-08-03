<script lang="ts">
import {
  DONATION_CONSENT_NOTICE,
  donationActionErrorMessage,
  donationAmountLabel,
  donationCadenceLabel,
  donationProviderLabel,
  type ScreenSectionProps,
} from "../../index";
import { namedFormAction } from "../../public-form-presentation";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime }: ScreenSectionProps = $props();
const donation = $derived(runtime.donation);
const offer = $derived(
  donation?.offer.state === "READY" ? donation.offer : undefined,
);
const idempotencyKey = $derived(runtime.idempotencyKeys?.["queue-donation"]);
const formReady = $derived(Boolean(offer && idempotencyKey));
const validationError = $derived(
  donation?.action.state === "ERROR" &&
    (donation.action.code === "INVALID_REQUEST" ||
      donation.action.code === "OFFER_CHANGED")
    ? donationActionErrorMessage(donation.action.code)
    : undefined,
);
const hasValidationError = $derived(validationError !== undefined);
const inputDescriptionIds = $derived(
  hasValidationError
    ? "donation-form-help donation-form-error-summary"
    : "donation-form-help",
);
const initialSelection = initialDonationSelection();
let selectedTierId = $state(initialSelection?.tierId ?? "");
let selectedCadence = $state(initialSelection?.cadence ?? "");
let selectedProvider = $state(initialSelection?.provider ?? "");
let consent = $state(initialSelection?.consentAccepted ?? false);

function initialDonationSelection() {
  const action = runtime.donation?.action;
  return action?.state === "ERROR" ? action.selection : undefined;
}
</script>

<SectionHeading {section} kicker="후원 요청" />
<form
  id="action-queue-donation"
  class="donation-form"
  method="POST"
  action={namedFormAction("queue-donation", runtime.search)}
  data-action-id="queue-donation"
  data-testid="pub_035__action__queue_donation"
>
  {#if offer}
    <input type="hidden" name="offerVersionId" value={offer.offerVersionId} />
    <input type="hidden" name="offerDigest" value={offer.offerDigest} />
  {/if}
  {#if idempotencyKey}
    <input type="hidden" name="idempotencyKey" value={idempotencyKey} />
  {/if}

  <p id="donation-form-help" class="field-help" aria-live="polite">
    승인된 테스트 픽스처 금액만 표시합니다. 운영 요금이나 운영 후원 금액
    기준이 아닙니다.
  </p>
  {#if validationError}
    <div
      id="donation-form-error-summary"
      class="validation-error-summary"
      role="alert"
      aria-labelledby="donation-form-error-heading"
    >
      <h3 id="donation-form-error-heading">입력 확인</h3>
      <p>{validationError}</p>
    </div>
  {/if}

  <fieldset
    disabled={!formReady}
    aria-describedby={inputDescriptionIds}
  >
    <legend>금액 티어 (필수)</legend>
    <div class="tier-list">
      {#if offer}
        {#each offer.tiers as tier (tier.tierId)}
          <label class:selected={selectedTierId === tier.tierId}>
            <input
              type="radio"
              name="tierId"
              value={tier.tierId}
              bind:group={selectedTierId}
              required
              aria-describedby={inputDescriptionIds}
            />
            <span>{donationAmountLabel(tier.amountWholeKrw)}</span>
            <small>테스트 픽스처</small>
          </label>
        {/each}
      {:else}
        <label>
          <input type="radio" name="tierId" disabled />
          <span>사용 가능한 금액 없음</span>
        </label>
      {/if}
    </div>
  </fieldset>

  <div class="choice-grid">
    <fieldset
      disabled={!formReady}
      aria-describedby={inputDescriptionIds}
    >
      <legend>후원 방식 (필수)</legend>
      <div class="inline-options">
        {#each offer?.cadences ?? [] as cadence (cadence)}
          <label>
            <input
              type="radio"
              name="cadence"
              value={cadence}
              bind:group={selectedCadence}
              required
              aria-describedby={inputDescriptionIds}
            />
            <span>{donationCadenceLabel(cadence)}</span>
          </label>
        {/each}
      </div>
    </fieldset>

    <label class="provider-field" for="donation-provider">
      <span>결제 제공자 (필수)</span>
      <select
        id="donation-provider"
        name="provider"
        bind:value={selectedProvider}
        required
        disabled={!formReady}
        aria-describedby={inputDescriptionIds}
        aria-invalid={hasValidationError ? "true" : undefined}
      >
        <option value="" disabled>제공자 선택</option>
        {#each offer?.providers ?? [] as provider (provider)}
          <option value={provider}>{donationProviderLabel(provider)}</option>
        {/each}
      </select>
    </label>
  </div>

  <label class="consent-field" for="donation-consent">
    <input
      id="donation-consent"
      name="consent"
      type="checkbox"
      value="true"
      bind:checked={consent}
      required
      disabled={!formReady}
      aria-describedby={inputDescriptionIds}
      aria-invalid={hasValidationError ? "true" : undefined}
    />
    <span>{DONATION_CONSENT_NOTICE} 위 고지와 테스트 접수에 동의합니다.</span>
  </label>

  <button
    class="primary-button"
    type="submit"
    disabled={!formReady}
    aria-disabled={!formReady}
  >테스트 후원 요청</button>
</form>

<style>
  .donation-form {
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
  .validation-error-summary {
    padding: 0.5rem 0.625rem;
    border-block: 1px solid var(--red-200);
    color: var(--red-700);
  }
  .validation-error-summary h3,
  .validation-error-summary p {
    margin: 0;
    font-size: 0.8125rem;
    line-height: 1.5;
  }
  .validation-error-summary h3 {
    font-weight: 650;
  }
  fieldset {
    min-width: 0;
    margin: 0;
    padding: 0;
    border: 0;
  }
  legend,
  .provider-field > span {
    margin-bottom: 0.375rem;
    color: var(--ink-900);
    font-size: 0.75rem;
    font-weight: 650;
  }
  .tier-list {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 10rem), 1fr));
    border-top: 1px solid var(--paper-200);
  }
  .tier-list label,
  .inline-options label {
    display: grid;
    grid-template-columns: auto minmax(0, 1fr);
    gap: 0.125rem 0.5rem;
    align-items: center;
    min-height: 44px;
    padding: 0.5rem;
    border-bottom: 1px solid var(--paper-200);
  }
  .tier-list label.selected {
    background: var(--paper-100);
  }
  .tier-list input {
    grid-row: 1 / 3;
  }
  .tier-list span,
  .inline-options span,
  .provider-field > span,
  .consent-field span {
    font-size: 0.8125rem;
    font-weight: 650;
  }
  .tier-list small {
    color: var(--ink-500);
    font-size: 0.75rem;
  }
  .choice-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 15rem), 1fr));
    gap: 0.75rem 1rem;
  }
  .inline-options {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    border-top: 1px solid var(--paper-200);
  }
  .provider-field {
    display: grid;
    align-content: start;
    gap: 0.25rem;
  }
  .provider-field select {
    min-width: 0;
  }
  .consent-field {
    display: grid;
    grid-template-columns: auto minmax(0, 1fr);
    gap: 0.5rem;
    align-items: start;
    padding: 0.5rem;
    border-block: 1px solid var(--paper-200);
  }
  .consent-field input {
    margin-top: 0.2rem;
  }
  button {
    min-height: 44px;
    justify-self: start;
  }
  @media (max-width: 520px) {
    .inline-options {
      grid-template-columns: minmax(0, 1fr);
    }
  }
</style>
