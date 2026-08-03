<script lang="ts">
import { untrack } from "svelte";

type AnswerRow = {
  questionId: string;
  questionLabel: string;
  text: string;
  attachmentIds: string[];
  updatedAt: string;
};
type Consent = {
  bodyConsent: boolean;
  attachmentConsents: {
    attachmentId: string;
    mayPublish: boolean;
    redactionAllowed: boolean;
  }[];
  identityDisplay: "ORGANIZATION_NAME" | "ROLE_ONLY" | "ANONYMOUS";
  redactionAcknowledged: boolean;
  excerptReviewRequested: boolean;
  consentedAt: string;
};
let {
  name,
  label,
  value,
  required = false,
  invalid = false,
  attachmentOptions = [],
  idPrefix = name,
}: {
  name: string;
  label: string;
  value?: unknown;
  required?: boolean;
  invalid?: boolean;
  attachmentOptions?: readonly { id: string; filename?: string }[];
  idPrefix?: string;
} = $props();
const isConsent = $derived(name.toLowerCase().includes("consent"));
const fieldHelpId = $derived(`${idPrefix}-help`);
const fieldErrorId = $derived(`${idPrefix}-error`);
const serializationId = $derived(`${idPrefix}-serialized`);
const describedBy = $derived(
  invalid ? `${fieldHelpId} ${fieldErrorId}` : fieldHelpId,
);
const controlId = (suffix: string) => `${idPrefix}-${suffix}`;
const attachmentId = (id: string) =>
  controlId(`attachment-${id.replace(/[^a-zA-Z0-9_-]+/gu, "-")}`);
const now = () => new Date().toISOString();
let rows = $state<AnswerRow[]>(untrack(() => toRows(value)));
let consent = $state<Consent>(untrack(() => toConsent(value)));
const encoded = $derived(
  isConsent ? JSON.stringify(consent) : JSON.stringify(rows),
);
function toRows(input: unknown): AnswerRow[] {
  if (!Array.isArray(input) || input.length === 0)
    return [
      {
        questionId: "",
        questionLabel: "질문 1",
        text: "",
        attachmentIds: [],
        updatedAt: now(),
      },
    ];
  const parsed = input.flatMap((item, index): AnswerRow[] => {
    if (typeof item !== "object" || item === null) return [];
    const row = item as Record<string, unknown>;
    const questionId = String(row.questionId ?? row.id ?? row.question ?? "");
    const questionLabel = String(
      row.questionLabel ??
        row.prompt ??
        row.questionText ??
        row.question ??
        `질문 ${index + 1}`,
    );
    const text = String(row.text ?? row.answer ?? row.response ?? "");
    const attachmentIds = Array.isArray(row.attachmentIds)
      ? row.attachmentIds.filter((id): id is string => typeof id === "string")
      : [];
    const updatedAt = typeof row.updatedAt === "string" ? row.updatedAt : now();
    return [{ questionId, questionLabel, text, attachmentIds, updatedAt }];
  });
  return parsed.length > 0
    ? parsed
    : [
        {
          questionId: "",
          questionLabel: "질문 1",
          text: "",
          attachmentIds: [],
          updatedAt: now(),
        },
      ];
}
function toConsent(input: unknown): Consent {
  const row =
    typeof input === "object" && input !== null
      ? (input as Record<string, unknown>)
      : {};
  const identity = row.identityDisplay;
  const legacyAttachments = Array.isArray(row.attachments)
    ? row.attachments.flatMap((item) => {
        if (typeof item === "string")
          return [
            { attachmentId: item, mayPublish: true, redactionAllowed: false },
          ];
        if (typeof item !== "object" || item === null) return [];
        const value = item as Record<string, unknown>;
        const attachmentId =
          typeof value.attachmentId === "string"
            ? value.attachmentId
            : typeof value.id === "string"
              ? value.id
              : "";
        return attachmentId
          ? [
              {
                attachmentId,
                mayPublish: value.mayPublish !== false,
                redactionAllowed: value.redactionAllowed === true,
              },
            ]
          : [];
      })
    : [];
  const canonicalAttachments = Array.isArray(row.attachmentConsents)
    ? row.attachmentConsents.flatMap((item) => {
        if (typeof item !== "object" || item === null) return [];
        const value = item as Record<string, unknown>;
        const attachmentId =
          typeof value.attachmentId === "string" ? value.attachmentId : "";
        return attachmentId
          ? [
              {
                attachmentId,
                mayPublish: value.mayPublish === true,
                redactionAllowed: value.redactionAllowed === true,
              },
            ]
          : [];
      })
    : legacyAttachments;
  return {
    bodyConsent: row.bodyConsent === true || row.body === true,
    attachmentConsents: canonicalAttachments,
    identityDisplay:
      identity === "ROLE_ONLY" || identity === "ANONYMOUS"
        ? identity
        : "ORGANIZATION_NAME",
    redactionAcknowledged: row.redactionAcknowledged === true,
    excerptReviewRequested: row.excerptReviewRequested === true,
    consentedAt: typeof row.consentedAt === "string" ? row.consentedAt : now(),
  };
}
</script>

<div class="structured-json-field" id={idPrefix} data-field-name={name}>
  {#if isConsent}
    <!--
      This control is the form-serialization bridge. The fieldset below
      contains the controls that users edit. It remains out of the tab order,
      but it must retain an accessible name because automated and assistive
      technology audits still inspect every named form control in the DOM.
    -->
    <textarea
      {name}
      id={serializationId}
      class="sr-only serialization-control"
      rows="1"
      aria-label={label}
      aria-describedby={describedBy}
      aria-invalid={invalid ? "true" : undefined}
      tabindex="-1"
      value={encoded}
      oninput={(event) => {
        // Keep the serialization bridge editable for receipt/review forms that
        // submit a canonical JSON payload directly. The visible controls remain
        // the normal editing surface; a valid direct edit simply rehydrates
        // the same canonical state.
        try {
          consent = toConsent(JSON.parse(event.currentTarget.value));
        } catch {
          // Leave the last valid state in place; the server will reject an
          // invalid payload and return the normal field-level error state.
        }
      }}
    ></textarea>
    <fieldset aria-describedby={describedBy}>
      <legend>{label}</legend>
      <label for={controlId("body-consent")}><input id={controlId("body-consent")} type="checkbox" checked={consent.bodyConsent} onchange={(event) => { consent = { ...consent, bodyConsent: event.currentTarget.checked }; }} aria-describedby={describedBy} /> <span>답변 본문 공개에 동의합니다.</span></label>
      <label for={controlId("identity-display")}><span>이름 표시</span><select id={controlId("identity-display")} value={consent.identityDisplay} onchange={(event) => { consent = { ...consent, identityDisplay: event.currentTarget.value as Consent["identityDisplay"] }; }} aria-required={required} aria-describedby={describedBy}><option value="ORGANIZATION_NAME">조직명</option><option value="ROLE_ONLY">역할만</option><option value="ANONYMOUS">익명</option></select></label>
      <label for={controlId("redaction-acknowledged")}><input id={controlId("redaction-acknowledged")} type="checkbox" checked={consent.redactionAcknowledged} onchange={(event) => { consent = { ...consent, redactionAcknowledged: event.currentTarget.checked }; }} aria-required={required} aria-describedby={describedBy} /> <span>민감정보 가림 원칙을 확인했습니다.</span></label>
      <label for={controlId("excerpt-review-requested")}><input id={controlId("excerpt-review-requested")} type="checkbox" checked={consent.excerptReviewRequested} onchange={(event) => { consent = { ...consent, excerptReviewRequested: event.currentTarget.checked }; }} aria-describedby={describedBy} /> <span>게시 전 발췌 검토를 요청합니다.</span></label>
      {#if attachmentOptions.length > 0}
        <fieldset class="attachment-consent-options">
          <legend>첨부 공개 범위</legend>
          {#each attachmentOptions as attachment}
            {@const existing = consent.attachmentConsents.find((item) => item.attachmentId === attachment.id)}
            <div class="attachment-consent-option">
              <input id={attachmentId(attachment.id)} type="checkbox" checked={existing?.mayPublish === true} onchange={(event) => {
                const checked = event.currentTarget.checked;
                const rest = consent.attachmentConsents.filter((item) => item.attachmentId !== attachment.id);
                consent = { ...consent, attachmentConsents: [...rest, { attachmentId: attachment.id, mayPublish: checked, redactionAllowed: existing?.redactionAllowed === true }] };
              }} aria-describedby={describedBy} />
              <label for={attachmentId(attachment.id)}>{attachment.filename ?? attachment.id} 공개에 동의합니다.</label>
            </div>
          {/each}
        </fieldset>
      {/if}
      <input type="hidden" name="consentedAt" value={consent.consentedAt} />
      <p id={fieldHelpId} class="field-help">동의 범위와 표시 방식은 제출 영수증에 immutable하게 기록됩니다.</p>
      {#if invalid}<p id={fieldErrorId} class="field-help field-error" role="alert">입력값을 확인한 뒤 다시 시도하세요.</p>{/if}
    </fieldset>
  {:else}
    <!-- See the consent bridge above: visible answer controls are authoritative
      for people, this named field only serializes the canonical JSON payload. -->
    <textarea
      {name}
      id={serializationId}
      class="sr-only serialization-control"
      rows="1"
      aria-label={label}
      aria-describedby={describedBy}
      aria-invalid={invalid ? "true" : undefined}
      tabindex="-1"
      value={encoded}
      oninput={(event) => {
        try {
          rows = toRows(JSON.parse(event.currentTarget.value));
        } catch {
          // Preserve the last valid state and let server validation surface
          // malformed direct edits as a field error.
        }
      }}
    ></textarea>
    <fieldset aria-describedby={describedBy}>
      <legend>{label}</legend>
      {#each rows as row, index (index)}
        <div class="structured-answer-row">
          <div class="field-readonly" aria-label={`질문 ${index + 1} 연결 상태`}><span>{row.questionLabel || `질문 ${index + 1}`}</span><output>{row.questionId ? "서버 질문에 연결됨" : "질문 연결 필요"}</output></div>
          <label for={controlId(`answer-${index + 1}`)}><span>답변</span><textarea id={controlId(`answer-${index + 1}`)} rows="4" aria-label={`${row.questionLabel || `질문 ${index + 1}`} 답변`} value={row.text} aria-required={required} aria-describedby={describedBy} oninput={(event) => { const text = event.currentTarget.value; rows = rows.map((current, currentIndex) => currentIndex === index ? { ...current, text, updatedAt: now() } : current); }}></textarea></label>
          <fieldset class="attachment-picker"><legend>첨부 공개 범위 (선택)</legend>
            {#if attachmentOptions.length > 0}
              {#each attachmentOptions as attachment}
                <label for={controlId(`answer-${index + 1}-attachment-${attachment.id.replace(/[^a-zA-Z0-9_-]+/gu, "-")}`)}><input id={controlId(`answer-${index + 1}-attachment-${attachment.id.replace(/[^a-zA-Z0-9_-]+/gu, "-")}`)} type="checkbox" checked={row.attachmentIds.includes(attachment.id)} onchange={(event) => {
                  const checked = event.currentTarget.checked;
                  rows = rows.map((current, currentIndex) => currentIndex === index ? { ...current, attachmentIds: checked ? [...current.attachmentIds, attachment.id] : current.attachmentIds.filter((id) => id !== attachment.id) } : current);
                }} aria-describedby={describedBy} /><span>{attachment.filename ?? "첨부 파일"} 연결</span></label>
              {/each}
            {:else}<p class="field-help">연결할 첨부가 없습니다.</p>{/if}
          </fieldset>
        </div>
      {/each}
      <p id={fieldHelpId} class="field-help">각 답변은 질문과 첨부 연결 상태를 함께 저장합니다.</p>
      {#if invalid}<p id={fieldErrorId} class="field-help field-error" role="alert">입력값을 확인한 뒤 다시 시도하세요.</p>{/if}
    </fieldset>
  {/if}
</div>

<style>
  .structured-json-field,
  fieldset {
    min-width: 0;
  }
  fieldset {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 16rem), 1fr));
    gap: 0.5rem 0.75rem;
    margin: 0;
    padding: 0.625rem;
    border: 1px solid var(--paper-200);
    border-radius: var(--radius-sm);
  }
  fieldset fieldset {
    padding: 0.5rem 0 0;
    border-width: 1px 0 0;
    border-radius: 0;
  }
  legend {
    padding-inline: 0.25rem;
    color: var(--ink-900);
    font-size: 0.875rem;
    font-weight: 650;
  }
  fieldset > label,
  .attachment-consent-option,
  .attachment-picker label {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    min-height: 2.25rem;
    font-size: 0.875rem;
  }
  fieldset > label > select {
    width: min(100%, 16rem);
    margin-left: auto;
  }
  input[type="checkbox"] {
    flex: 0 0 auto;
  }
  .structured-answer-row {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 18rem), 1fr));
    gap: 0.5rem 0.75rem;
    padding-block: 0.625rem;
    border-top: 1px solid var(--paper-200);
  }
  .structured-answer-row:first-of-type {
    border-top: 0;
  }
  .structured-answer-row > label {
    display: grid;
    gap: 0.25rem;
    color: var(--ink-900);
    font-size: 0.8125rem;
    font-weight: 650;
  }
  .field-readonly {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    grid-column: 1 / -1;
    gap: 0.75rem;
    align-items: baseline;
  }
  .attachment-consent-options,
  .structured-json-field > fieldset > .field-help {
    grid-column: 1 / -1;
  }
  .attachment-consent-options {
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 16rem), 1fr));
  }
  .field-readonly span {
    font-weight: 650;
    overflow-wrap: anywhere;
  }
  .field-readonly output,
  .field-help {
    color: var(--ink-700);
    font-size: 0.75rem;
  }
  .field-help {
    margin: 0;
    line-height: 1.5;
  }
  .field-error {
    color: var(--red-700);
  }
  .serialization-control {
    position: absolute;
    width: 1px;
    height: 1px;
    padding: 0;
    margin: -1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
    white-space: nowrap;
    border: 0;
  }
  @media (max-width: 620px) {
    fieldset,
    .structured-answer-row,
    .attachment-consent-options {
      grid-template-columns: minmax(0, 1fr);
    }
    fieldset {
      padding: 0.625rem;
    }
    fieldset > label,
    .attachment-consent-option,
    .attachment-picker label {
      align-items: flex-start;
      flex-wrap: wrap;
      min-height: 44px;
    }
    fieldset > label > select {
      width: 100%;
      margin-left: 0;
    }
    .field-readonly {
      grid-template-columns: minmax(0, 1fr);
      gap: 0.25rem;
    }
  }
  @media (forced-colors: active) {
    fieldset {
      border-color: CanvasText;
      background: Canvas;
      color: CanvasText;
    }
  }
</style>
