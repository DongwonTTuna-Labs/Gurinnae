<script lang="ts">
  import type { ScreenSectionProps } from "../../index";
  import { toRsp006ViewModel } from "../../view-models/rsp-006";
  import { humanFieldLabel, typedScreenViewModel } from "../../screen-contract";
  import SectionHeading from "./SectionHeading.svelte";

  let { section, screen, runtime, embedded = false }: ScreenSectionProps & { embedded?: boolean } = $props();
  const contract = $derived(typedScreenViewModel(screen));
  const vm = $derived(screen.id === "RSP-006" ? toRsp006ViewModel(runtime.data) : null);
  const preview = $derived(screen.id === "RSP-005" ? asRecord(runtime.data.getResponseSubmissionPreview) : null);
  const previewAnswers = $derived(Array.isArray(preview?.answers) ? preview.answers.filter(isRecord) : []);
  const previewAttachments = $derived(Array.isArray(preview?.attachments) ? preview.attachments.filter(isRecord) : []);
  const previewConsent = $derived(asRecord(preview?.publicationConsent));
  const receiptFacts = $derived(vm ? [
    ["receiptId", vm.receiptId],
    ["receiptTitle", vm.receiptTitle],
    ["receiptStatus", vm.receiptStatus],
    ["receiptVersion", vm.receiptVersion],
    ["submissionSummary", vm.submissionSummary],
    ["requestId", vm.submittedItems.requestId],
    ["submittedAt", vm.submittedItems.submittedAt],
    ["submissionDigest", vm.submittedItems.submissionDigest],
    ["retentionNotice", vm.submittedItems.retentionNotice],
    ["answerCount", vm.submittedItems.answerCount],
    ["attachmentCount", vm.submittedItems.attachmentCount],
    ["publicationScope", vm.submittedItems.publicationScope],
  ].filter((item): item is [string, string | number] => item[1] !== null) : []);
  const links = $derived(vm?.links ?? []);
  function asRecord(value: unknown): Record<string, unknown> | null { return typeof value === "object" && value !== null && !Array.isArray(value) ? value as Record<string, unknown> : null; }
  function isRecord(value: unknown): value is Record<string, unknown> { return asRecord(value) !== null; }
</script>

{#if !embedded}<SectionHeading {section} kicker="접수된 내용" />{/if}
<div class="journey-section" data-journey={contract.journey} data-region={contract.sections.find((item) => item.id === section.id)?.region ?? "state"} aria-busy={runtime.state === "loading"}>
  {#if screen.id === "RSP-005"}
    {#if section.id === "answers"}
      <p class="journey-lead">서버가 계산한 제출 preview입니다. 질문 ID·답변·첨부 연결을 확인한 뒤 수정 링크로 돌아갈 수 있습니다.</p>
      {#if previewAnswers.length > 0}<dl class="semantic-facts" aria-label="질문별 제출 preview">{#each previewAnswers as answer}<div><dt>{String(answer.questionId ?? "질문")}</dt><dd>{String(answer.text ?? "답변 없음")} · 첨부 {Array.isArray(answer.attachmentIds) ? answer.attachmentIds.length : 0}개</dd></div>{/each}</dl>
      {:else}<p class="empty-message" role={runtime.state === "error" ? "alert" : "status"}>질문별 preview가 없습니다. 답변 화면에서 저장한 뒤 다시 확인하세요.</p>{/if}
      {#if typeof preview?.submissionDigest === "string"}<p class="projection-provenance">submission digest: {preview.submissionDigest}</p>{/if}
    {:else if section.id === "consent"}
      <p>본문 공개: {previewConsent?.body === true ? "동의" : "미동의"} · 민감정보 가림 확인: {previewConsent?.redactionAcknowledged === true ? "확인" : "미확인"}</p>
      <p>첨부 공개 {Array.isArray(previewConsent?.attachments) ? previewConsent.attachments.length : 0}개 · 범위 설명: {String(previewConsent?.scopeExplanation ?? "확인 필요")}</p>
    {:else if section.id === "attachments"}
      <p>서버가 확인한 첨부 {previewAttachments.length}개를 표시합니다.</p>
    {/if}
  {:else}
  <p class="journey-lead">제출 당시의 영수증과 요약만 표시합니다. 수정은 보충자료 경로에서 새 receipt로 남습니다.</p>
  {#if receiptFacts.length > 0}
    <dl class="semantic-facts" aria-label="접수 영수증 확인 정보">
      {#each receiptFacts as [key, value]}<div><dt>{humanFieldLabel(key)}</dt><dd>{String(value)}</dd></div>{/each}
    </dl>
  {:else if runtime.state === "loading"}<p role="status">영수증을 불러오는 중입니다.</p>
  {:else}<p class="empty-message" role={runtime.state === "error" ? "alert" : "status"}>권위 영수증 projection이 없습니다. 제출 상태를 다시 확인하세요.</p>{/if}
  {#if links.length > 0}
    <nav class="receipt-links" aria-label="영수증 관련 작업">{#each links as link}<a class="secondary-button" href={link.href}>{link.label}</a>{/each}</nav>
  {/if}
  {#if runtime.state === "conflict"}<p class="inline-state conflict" role="alert">영수증 version이 변경되었습니다. 최신 영수증을 다시 확인하세요.</p>
  {:else if runtime.state === "stale"}<p class="inline-state stale" role="status">영수증 정보가 오래되었습니다. 새로고침 후 다운로드하세요.</p>
  {:else if runtime.state === "forbidden" || runtime.state === "unauthenticated"}<p class="inline-state forbidden" role="alert">현재 세션에서는 이 영수증을 확인할 수 없습니다.</p>{/if}
  {/if}
</div>
