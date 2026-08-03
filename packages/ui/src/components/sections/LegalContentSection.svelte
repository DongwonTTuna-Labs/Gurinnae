<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import { authoritySectionStatus } from "../../screen-projection-values";
import ProjectionValue from "../ProjectionValue.svelte";
import PrivacyRequestStatus from "./PrivacyRequestStatus.svelte";
import SectionHeading from "./SectionHeading.svelte";

let { section, screen, runtime, projection }: ScreenSectionProps = $props();
const body = $derived(
  projection?.fields.find(
    (field) => field.name === section.id && field.known && field.value !== null,
  ),
);
const retentionTableRequired = $derived(
  (screen.id === "PUB-031" && section.id === "retention") ||
    (screen.id === "PUB-032" && section.id === "data"),
);
const retentionSchedules = $derived(
  retentionTableRequired ? projection?.retentionSchedules : undefined,
);
const retentionScheduleLabel = $derived(
  screen.id === "PUB-031"
    ? "개인정보 보존 일정"
    : "이용약관 기록 유형별 보존 일정",
);
const retentionScheduleCaption = $derived(
  screen.id === "PUB-031"
    ? "승인된 개인정보 보존 일정"
    : "승인된 이용약관 기록 유형별 보존 일정",
);
const retentionScheduleMissingMessage = $derived(
  screen.id === "PUB-031"
    ? "승인된 보존 일정을 확인할 수 없어 개인정보 처리방침 표시를 보류했습니다."
    : "승인된 보존 일정이 없어 이용약관을 공개할 수 없습니다.",
);
const privacyRequestStatus = $derived(
  screen.id === "PUB-031" && section.id === "rights"
    ? runtime.privacyRequestStatus
    : undefined,
);
const sectionStatus = $derived(
  authoritySectionStatus({
    projectionPresent: projection !== undefined,
    runtimeState: runtime.state,
    declaredFieldCount: projection?.fields.length ?? 0,
    knownFieldCount:
      projection?.fields.filter((field) => field.known).length ?? 0,
    ...(projection
      ? {
          projectionState: projection.state,
          errorMessage: projection.errorMessage,
        }
      : {}),
  }),
);
const retentionTableMissing = $derived(
  retentionTableRequired &&
    !sectionStatus?.suppressValues &&
    !retentionSchedules?.length,
);
</script>

<SectionHeading {section} kicker="법률 문서" />
<div class="legal-content" data-projection-state={projection?.state ?? "UNKNOWN"}>
  {#if sectionStatus}
    <p
      class:conflict={sectionStatus.tone === "conflict"}
      class:stale={sectionStatus.tone === "stale"}
      class="inline-state"
      role={sectionStatus.tone === "conflict" ? "alert" : "status"}
    >{sectionStatus.message}</p>
  {/if}
  {#if retentionTableMissing}
    <p class="inline-state conflict" role="alert">{retentionScheduleMissingMessage}</p>
  {:else if !sectionStatus?.suppressValues && body}
    <p class="legal-body"><ProjectionValue name={body.name} label={body.label} value={body.value} /></p>
    {#if retentionSchedules}
      <div class="retention-table-scroll" role="region" aria-label={retentionScheduleLabel}>
        <table>
          <caption class="sr-only">{retentionScheduleCaption}</caption>
          <thead>
            <tr>
              <th scope="col">기록 유형</th>
              <th scope="col">처리 목적</th>
              <th scope="col">법적 근거</th>
              <th scope="col">기산점</th>
              <th scope="col">활성 보존</th>
              <th scope="col">백업 보존</th>
              <th scope="col">종료 처리</th>
              <th scope="col">효력 발생</th>
              <th scope="col">검토 만료</th>
            </tr>
          </thead>
          <tbody>
            {#each retentionSchedules as item (item.recordClass)}
              <tr>
                <th scope="row">{item.recordClass}</th>
                <td>{item.purpose}</td>
                <td>{item.lawfulBasis}</td>
                <td>{item.trigger}</td>
                <td>{item.activeDuration}</td>
                <td>{item.backupDuration}</td>
                <td>{item.terminalAction}</td>
                <td>{item.effectiveAt}</td>
                <td>{item.reviewExpiresAt}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}
    {#if privacyRequestStatus}<PrivacyRequestStatus status={privacyRequestStatus} />{/if}
  {/if}
</div>

<style>
  .legal-content {
    min-width: 0;
    border-top: 1px solid var(--paper-200);
  }

  .legal-body,
  .inline-state {
    margin: 0;
    padding: 0.5rem;
    border-bottom: 1px solid var(--paper-200);
    color: var(--ink-800);
    font-size: 0.875rem;
    line-height: 1.55;
  }

  .retention-table-scroll {
    max-width: 100%;
    overflow-x: auto;
    border-bottom: 1px solid var(--paper-200);
  }

  table {
    width: 100%;
    min-width: 72rem;
    table-layout: fixed;
    border-collapse: collapse;
    color: var(--ink-800);
    font-size: 0.75rem;
    text-align: left;
  }

  th,
  td {
    padding: 0.375rem 0.5rem;
    border-bottom: 1px solid var(--paper-200);
    line-height: 1.4;
    overflow-wrap: anywhere;
    vertical-align: top;
  }

  thead th {
    border-bottom-color: var(--ink-700);
    color: var(--ink-500);
    font-weight: 650;
  }

  tbody th {
    color: var(--ink-900);
    font-weight: 650;
  }

  tbody tr:last-child > :is(th, td) {
    border-bottom: 0;
  }

  .inline-state {
    background: var(--paper-50);
    color: var(--ink-700);
  }

  .inline-state.conflict {
    border-color: var(--red-500);
    background: var(--red-50);
    color: var(--red-900);
  }

  .inline-state.stale {
    border-color: var(--amber-500);
    background: var(--amber-50);
    color: var(--amber-900);
  }
</style>
