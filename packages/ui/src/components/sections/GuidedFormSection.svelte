<script lang="ts">
  import type { ScreenSectionProps } from "../../index";
  import { humanFieldLabel } from "../../screen-contract";
  import SectionHeading from "./SectionHeading.svelte";
  import StructuredJsonField from "../StructuredJsonField.svelte";

  let { section, screen, runtime }: ScreenSectionProps = $props();
  const fieldCount = $derived(Object.values(runtime.forms).reduce((sum, fields) => sum + fields.length, 0));
  const fieldGroups = $derived(Object.entries(runtime.forms).map(([actionId, fields]) => ({ actionId, fields })));
  const draft = $derived(record(runtime.data.getResponseDraft));
  const saveAction = $derived(screen.actions.find((action) => action.id === "save-draft"));
  const saveFields = $derived(runtime.forms["save-draft"] ?? []);
  const isAnswerScreen = $derived(screen.id === "RSP-003" && section.id === "questions");
  const preview = $derived(record(runtime.data.getResponseSubmissionPreview));
  const previewConsent = $derived(record(preview?.publicationConsent));
  const answers = $derived(draft?.answers ?? []);
  const consent = $derived(draft?.publicationConsent ?? {});
  function record(value: unknown): Record<string, unknown> | null { return typeof value === "object" && value !== null && !Array.isArray(value) ? value as Record<string, unknown> : null; }
</script>

<SectionHeading {section} kicker="단계별 입력" />
<div class="guided-form-intro">
  <p>필수 입력, 검토, 제출 순서로 진행합니다. 세션과 권한은 각 단계에서 서버가 다시 확인합니다.</p>
  {#if screen.id === "RSP-005" && (section.id === "consent" || section.id === "authority" || section.id === "consequence")}
    {#if section.id === "consent"}<p>본문 공개: {previewConsent?.body === true ? "동의" : "미동의"}</p><p>민감정보 가림 확인: {previewConsent?.redactionAcknowledged === true ? "확인" : "미확인"} · 첨부 공개 {Array.isArray(previewConsent?.attachments) ? previewConsent.attachments.length : 0}개</p>
    {:else if section.id === "authority"}<p>제출 권한과 세션 범위는 서버가 preview 시점에 확인합니다. 권한이 확인되지 않으면 제출 버튼을 사용할 수 없습니다.</p>
    {:else}<p>제출 후에는 immutable receipt와 submission digest가 발급되며, 수정은 보충자료 경로에서 새 영수증으로 남습니다.</p>{/if}
  {:else if isAnswerScreen && saveAction}
    <form method="POST" action={`?/${saveAction.id}`} class="guided-response-form" data-action-id={saveAction.id}>
      {#if runtime.csrfToken}<input type="hidden" name="csrfToken" value={runtime.csrfToken} />{/if}
      {#if runtime.idempotencyKeys?.[saveAction.id]}<input type="hidden" name="idempotencyKey" value={runtime.idempotencyKeys[saveAction.id]} />{/if}
      {#each saveFields as field (field.name)}
        {#if field.name === "answers"}<StructuredJsonField name="answers" label="질문별 답변" value={answers} required={field.required} />
        {:else if field.name === "publicationConsent"}<StructuredJsonField name="publicationConsent" label="공개 동의" value={consent} required={field.required} />
        {:else if field.readonly}<input type="hidden" name={field.name} value={field.value ?? ""} />
        {:else if field.name !== "answers" && field.name !== "publicationConsent"}<label><span>{field.label && field.label !== field.name ? field.label : humanFieldLabel(field.name)}{field.required ? " (필수)" : ""}</span><input name={field.name} type={field.type} value={field.value ?? ""} required={field.required} /></label>{/if}
      {/each}
      <button class="primary-button" type="submit">{saveAction.label}</button>
    </form>
  {:else}
    <p>현재 계약에서 <strong>{fieldCount}</strong>개 입력 필드를 준비했습니다.</p>
    {#if fieldGroups.length > 0}<dl class="guided-field-summary" aria-label="입력 항목 안내">{#each fieldGroups as group (group.actionId)}<div><dt>{group.actionId}</dt><dd>{group.fields.map((field) => `${field.label && field.label !== field.name ? field.label : field.name}${field.required ? " · 필수" : ""}`).join(" · ")}</dd></div>{/each}</dl>
    {:else}<p role="status">현재 세션에서 입력할 항목이 없습니다.</p>{/if}
  {/if}
</div>
