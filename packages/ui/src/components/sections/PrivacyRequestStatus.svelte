<script lang="ts">
import type { ScreenRuntime } from "../../index";
import { projectionScalarText } from "../../projection-value";

let {
  status,
}: {
  status: NonNullable<ScreenRuntime["privacyRequestStatus"]>;
} = $props();

const requestTypeLabel = (
  value: "ACCESS" | "CORRECTION" | "DELETION" | "RESTRICTION",
) => {
  switch (value) {
    case "ACCESS":
      return "열람";
    case "CORRECTION":
      return "정정";
    case "DELETION":
      return "삭제";
    case "RESTRICTION":
      return "처리정지";
  }
};
const stateLabel = (
  value: "RECEIVED" | "REVIEW" | "APPROVED" | "REJECTED" | "COMPLETED",
) => {
  switch (value) {
    case "RECEIVED":
      return "접수";
    case "REVIEW":
      return "검토";
    case "APPROVED":
      return "처리 승인";
    case "REJECTED":
      return "거절";
    case "COMPLETED":
      return "완료";
  }
};
const identityLabel = (value: "PENDING_VERIFICATION" | "VERIFIED") =>
  value === "VERIFIED" ? "확인 완료" : "확인 대기";
const nextActionLabel = (
  value:
    | "VERIFY_IDENTITY"
    | "AWAIT_REVIEW"
    | "AWAIT_DECISION"
    | "AWAIT_EXECUTION"
    | "REVIEW_REFUSAL_NOTICE"
    | "COMPLETE",
) => {
  switch (value) {
    case "VERIFY_IDENTITY":
      return "신원 확인";
    case "AWAIT_REVIEW":
      return "검토 대기";
    case "AWAIT_DECISION":
      return "결정 대기";
    case "AWAIT_EXECUTION":
      return "처리 대기";
    case "REVIEW_REFUSAL_NOTICE":
      return "거절 통지 확인";
    case "COMPLETE":
      return "처리 완료";
  }
};
const dateLabel = (name: string, value: string) =>
  projectionScalarText(name, value) ?? "확인 필요";
</script>

{#if status.loadState === "UNAVAILABLE"}
  <p class="privacy-request-state" role="status">개인정보 요청 상태를 지금 확인할 수 없습니다.</p>
{:else}
  <dl class="privacy-request-ledger" aria-label="개인정보 요청 처리 상태">
    <div><dt>요청 유형</dt><dd>{requestTypeLabel(status.requestType)}</dd></div>
    <div><dt>처리 상태</dt><dd>{stateLabel(status.state)}</dd></div>
    <div><dt>신원 확인</dt><dd>{identityLabel(status.identityState)}</dd></div>
    <div><dt>처리 기한</dt><dd>{status.dueAt ? dateLabel("dueAt", status.dueAt) : "신원 확인 후 산정"}</dd></div>
    <div><dt>다음 단계</dt><dd>{nextActionLabel(status.nextActionCode)}</dd></div>
    <div><dt>기준 시각</dt><dd>{dateLabel("asOf", status.asOf)}</dd></div>
  </dl>
{/if}

<style>
  .privacy-request-state {
    margin: 0;
    padding: 0.5rem;
    border-bottom: 1px solid var(--paper-200);
    background: var(--paper-50);
    color: var(--ink-700);
    font-size: 0.8125rem;
    line-height: 1.5;
  }

  .privacy-request-ledger {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 1px;
    margin: 0;
    border-bottom: 1px solid var(--paper-200);
    background: var(--paper-200);
  }

  .privacy-request-ledger > div {
    min-width: 0;
    padding: 0.375rem 0.5rem;
    background: var(--paper-0);
  }

  dt {
    color: var(--ink-500);
    font-size: 0.75rem;
    font-weight: 650;
  }

  dd {
    margin: 0.125rem 0 0;
    color: var(--ink-900);
    font-size: 0.8125rem;
    font-weight: 650;
  }

  @media (max-width: 620px) {
    .privacy-request-ledger {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }
  }
</style>
