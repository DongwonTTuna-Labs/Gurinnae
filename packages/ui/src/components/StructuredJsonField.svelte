<script lang="ts">
  import { untrack } from "svelte";
  type AnswerRow = {
    questionId: string;
    text: string;
    attachmentIds: string[];
    updatedAt: string;
  };
  type Consent = {
    bodyConsent: boolean;
    attachmentConsents: { attachmentId: string; mayPublish: boolean; redactionAllowed: boolean }[];
    identityDisplay: "ORGANIZATION_NAME" | "ROLE_ONLY" | "ANONYMOUS";
    redactionAcknowledged: boolean;
    excerptReviewRequested: boolean;
    consentedAt: string;
  };
  let { name, label, value, required = false }: { name: string; label: string; value?: unknown; required?: boolean } = $props();
  const isConsent = $derived(name.toLowerCase().includes("consent"));
  let rows = $state<AnswerRow[]>(untrack(() => toRows(value)));
  let consent = $state<Consent>(untrack(() => toConsent(value)));
  const encoded = $derived(isConsent ? JSON.stringify(consent) : JSON.stringify(rows));
  const now = () => new Date().toISOString();
  function toRows(input: unknown): AnswerRow[] {
    if (!Array.isArray(input) || input.length === 0) return [{ questionId: "", text: "", attachmentIds: [], updatedAt: now() }];
    const parsed = input.flatMap((item): AnswerRow[] => {
      if (typeof item !== "object" || item === null) return [];
      const row = item as Record<string, unknown>;
      const questionId = String(row.questionId ?? row.id ?? row.question ?? "");
      const text = String(row.text ?? row.answer ?? row.response ?? "");
      const attachmentIds = Array.isArray(row.attachmentIds) ? row.attachmentIds.filter((id): id is string => typeof id === "string") : [];
      const updatedAt = typeof row.updatedAt === "string" ? row.updatedAt : now();
      return [{ questionId, text, attachmentIds, updatedAt }];
    });
    return parsed.length > 0 ? parsed : [{ questionId: "", text: "", attachmentIds: [], updatedAt: now() }];
  }
  function toConsent(input: unknown): Consent {
    const row = typeof input === "object" && input !== null ? input as Record<string, unknown> : {};
    const identity = row.identityDisplay;
    return {
      bodyConsent: row.bodyConsent === true || row.body === true,
      attachmentConsents: Array.isArray(row.attachmentConsents) ? row.attachmentConsents.flatMap((item) => {
        if (typeof item !== "object" || item === null) return [];
        const value = item as Record<string, unknown>;
        const attachmentId = typeof value.attachmentId === "string" ? value.attachmentId : "";
        return attachmentId ? [{ attachmentId, mayPublish: value.mayPublish === true, redactionAllowed: value.redactionAllowed === true }] : [];
      }) : [],
      identityDisplay: identity === "ROLE_ONLY" || identity === "ANONYMOUS" ? identity : "ORGANIZATION_NAME",
      redactionAcknowledged: row.redactionAcknowledged === true,
      excerptReviewRequested: row.excerptReviewRequested === true,
      consentedAt: typeof row.consentedAt === "string" ? row.consentedAt : now(),
    };
  }
</script>

<div class="structured-json-field" data-field-name={name}>
  <input type="hidden" {name} value={encoded} {required} />
  {#if isConsent}
    <fieldset>
      <legend>{label}</legend>
      <label><input type="checkbox" bind:checked={consent.bodyConsent} /> <span>답변 본문 공개에 동의합니다.</span></label>
      <label><span>이름 표시</span><select bind:value={consent.identityDisplay} required={required}><option value="ORGANIZATION_NAME">조직명</option><option value="ROLE_ONLY">역할만</option><option value="ANONYMOUS">익명</option></select></label>
      <label><input type="checkbox" bind:checked={consent.redactionAcknowledged} required={required} /> <span>민감정보 가림 원칙을 확인했습니다.</span></label>
      <label><input type="checkbox" bind:checked={consent.excerptReviewRequested} /> <span>게시 전 발췌 검토를 요청합니다.</span></label>
      <p class="field-help">동의 범위와 표시 방식은 제출 영수증에 immutable하게 기록됩니다.</p>
    </fieldset>
  {:else}
    <fieldset>
      <legend>{label}</legend>
      {#each rows as row, index (index)}
        <div class="structured-answer-row">
          <label><span>질문 ID</span><input value={row.questionId} required={required} oninput={(event) => { row.questionId = event.currentTarget.value; }} /></label>
          <label><span>답변</span><textarea rows="4" value={row.text} required={required} oninput={(event) => { row.text = event.currentTarget.value; row.updatedAt = now(); }}></textarea></label>
          <label><span>첨부 ID (선택, 쉼표로 구분)</span><input value={row.attachmentIds.join(", ")} oninput={(event) => { row.attachmentIds = event.currentTarget.value.split(",").map((id) => id.trim()).filter(Boolean); }} /></label>
        </div>
      {/each}
    </fieldset>
  {/if}
</div>
