<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import {
  type PublicLedgerViewModel,
  publicLedgerActionRowIndex,
  publicLedgerForSection,
  publicLedgerRenderState,
} from "../../public-ledger";
import PublicSectionStatusNotice from "../PublicSectionStatusNotice.svelte";
import SectionHeading from "./SectionHeading.svelte";

type PublicLedgerProps = Omit<ScreenSectionProps, "runtime"> & {
  runtime: ScreenSectionProps["runtime"] & {
    publicLedger?: PublicLedgerViewModel;
  };
};

let { section, screen, runtime }: PublicLedgerProps = $props();
const ledger = $derived(
  publicLedgerForSection(runtime.publicLedger, screen.id, section.id),
);
const renderState = $derived(publicLedgerRenderState(runtime.state, ledger));
const actionRowIndex = $derived(publicLedgerActionRowIndex(ledger));
// PUB-001 already carries the same non-conclusion meaning in its fixed header.
// Keep the machine-readable collection notice, but do not render a third
// human-facing repetition beside the corrections section notice.
const showCollectionNotices = $derived(
  !(screen.id === "PUB-001" && section.id === "recent"),
);
let copiedIdentifier = $state<string | null>(null);
let copyFailed = $state(false);

async function copyIdentifier(value: string): Promise<void> {
  copyFailed = false;
  if (!navigator.clipboard) {
    copyFailed = true;
    return;
  }
  try {
    await navigator.clipboard.writeText(value);
    copiedIdentifier = value;
  } catch {
    copyFailed = true;
  }
}
</script>

<SectionHeading {section} kicker="공개 대장" />
<div
  class="public-ledger"
  data-projection-state={renderState.projectionState}
  aria-busy={renderState.projectionState === "LOADING"}
>
  {#if ledger && showCollectionNotices}
    {#each ledger.collectionNotices as notice}
      <PublicSectionStatusNotice {notice} />
    {/each}
  {/if}
  {#if !renderState.showRows}
    <p
      class:conflict={renderState.alert}
      class="ledger-state"
      role={renderState.alert ? "alert" : "status"}
      aria-live="polite"
    >{renderState.message}</p>
  {:else if ledger}
    <div class="table-scroll" role="region" aria-label={`${screen.title} 공개 대장`}>
      <table>
        <caption class="sr-only">{screen.title} 공개 대장</caption>
        <thead>
          <tr>
            <th scope="col">식별자</th>
            <th scope="col">제목·요약</th>
            <th scope="col">유형</th>
            <th scope="col">상태</th>
            <th scope="col">핵심 수치</th>
          </tr>
        </thead>
        <tbody>
          {#each ledger.rows as row, rowIndex (row.key)}
            <tr>
              <th scope="row" class="identifier">
                <span title={row.identifier.title}>{row.identifier.text}</span>
                {#if row.identifier.secondary}<small>{row.identifier.secondary}</small>{/if}
                {#if row.identifier.copyText}
                  <button
                    type="button"
                    class="copy-value"
                    onclick={() => copyIdentifier(row.identifier.copyText ?? "")}
                  >
                    {copyFailed
                      ? "복사 실패"
                      : copiedIdentifier === row.identifier.copyText
                        ? "복사됨"
                        : "복사"}
                    <span class="sr-only"> · {row.identifier.label} 전체값</span>
                  </button>
                {/if}
              </th>
              <td class="title-summary">
                {#if row.href}
                  <a
                    href={row.href}
                    data-ledger-row-link
                    data-action-id={rowIndex === actionRowIndex ? ledger.actionId : undefined}
                  >{row.title.text}</a>
                {:else}
                  <strong>{row.title.text}</strong>
                {/if}
                {#if row.summary}<span>{row.summary.text}</span>{/if}
              </td>
              <td class="kind">{row.kind.text}</td>
              <td class="status">
                {#if row.status}
                  <span class="status-value">
                    <span class="status-dot" data-tone={row.status.tone} aria-hidden="true"></span>
                    <span>{row.status.text}</span>
                  </span>
                {/if}
              </td>
              <td class="metric">
                {#if row.metric}
                  <small>{row.metric.label}</small>
                  <span title={row.metric.title}>{row.metric.text}</span>
                  {#if row.metric.secondary}<small>{row.metric.secondary}</small>{/if}
                {/if}
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}
</div>

<style>
  .public-ledger {
    display: grid;
    min-width: 0;
  }

  .table-scroll {
    max-width: 100%;
    overflow-x: auto;
    border-block: 1px solid var(--paper-200);
    background: var(--paper-0);
  }

  table {
    width: 100%;
    min-width: 52rem;
    table-layout: fixed;
    border-collapse: collapse;
    color: var(--ink-900);
    font-size: 0.8125rem;
    text-align: left;
  }

  th,
  td {
    min-width: 0;
    padding: 0.375rem 0.5rem;
    border-bottom: 1px solid var(--paper-200);
    line-height: 1.35;
    overflow-wrap: anywhere;
    vertical-align: middle;
  }

  thead th {
    border-bottom-color: var(--ink-700);
    color: var(--ink-500);
    font-size: 0.75rem;
    font-weight: 650;
  }

  tbody tr:last-child > :is(th, td) {
    border-bottom: 0;
  }

  tbody tr:hover {
    background: var(--paper-50);
  }

  .identifier {
    width: 16%;
    color: var(--ink-600);
    font-weight: 500;
  }

  .identifier small,
  .metric small {
    display: block;
    color: var(--ink-500);
    font-size: 0.75rem;
  }

  .copy-value {
    min-height: 1.75rem;
    margin-left: 0.375rem;
    padding: 0.125rem 0.375rem;
    border: 1px solid var(--paper-300);
    border-radius: 3px;
    background: var(--paper-0);
    color: var(--blue-700);
    font: inherit;
    font-size: 0.75rem;
    cursor: pointer;
  }

  .copy-value:focus-visible {
    outline: 2px solid var(--blue-500);
    outline-offset: 2px;
  }

  .title-summary {
    width: 38%;
  }

  .title-summary a,
  .title-summary strong {
    display: block;
    color: var(--ink-900);
    font-size: 0.875rem;
    font-weight: 650;
  }

  .title-summary a {
    color: var(--blue-700);
    text-decoration-thickness: 1px;
    text-underline-offset: 0.18em;
  }

  .title-summary span {
    display: block;
    max-width: 100%;
    margin-top: 0.125rem;
    overflow: hidden;
    color: var(--ink-600);
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .kind {
    width: 14%;
  }

  .status,
  .metric {
    width: 16%;
  }

  .status-value {
    display: inline-flex;
    gap: 0.375rem;
    align-items: center;
  }

  .status :global(.public-status-notice) {
    max-width: 22rem;
  }

  .status-dot {
    width: 0.5rem;
    height: 0.5rem;
    flex: 0 0 auto;
    border-radius: 50%;
    background: var(--ink-300);
  }

  .status-dot[data-tone="positive"] {
    background: var(--green-500, #237a4b);
  }

  .status-dot[data-tone="warning"] {
    background: var(--amber-500);
  }

  .status-dot[data-tone="critical"] {
    background: var(--red-500);
  }

  .ledger-state {
    display: flex;
    gap: 0.5rem;
    align-items: flex-start;
    margin: 0;
    padding: 0.5rem 0.625rem;
    border-block: 1px solid var(--paper-200);
    background: var(--paper-50);
    color: var(--ink-700);
    font-size: 0.875rem;
  }

  .ledger-state::before {
    width: 0.45rem;
    height: 0.45rem;
    flex: 0 0 auto;
    margin-top: 0.4em;
    border-radius: 50%;
    background: var(--ink-300);
    content: "";
  }

  .public-ledger[data-projection-state="BLOCKED"] .ledger-state.conflict,
  .public-ledger[data-projection-state="ERROR"] .ledger-state.conflict {
    color: var(--red-900);
  }

  @media (max-width: 620px) {
    .table-scroll {
      overflow-x: visible;
    }

    table {
      min-width: 0;
    }

    thead {
      position: absolute;
      width: 1px;
      height: 1px;
      padding: 0;
      overflow: hidden;
      clip: rect(0, 0, 0, 0);
      white-space: nowrap;
      border: 0;
    }

    tbody,
    tbody tr {
      display: block;
    }

    tbody tr {
      display: flex;
      flex-wrap: wrap;
      padding: 0.375rem 0;
      border-bottom: 1px solid var(--paper-200);
    }

    tbody tr:last-child {
      border-bottom: 0;
    }

    tbody tr > :is(th, td) {
      width: auto;
      padding: 0.125rem 0.5rem;
      border: 0;
    }

    .identifier,
    .title-summary {
      box-sizing: border-box;
      flex: 0 0 100%;
      max-width: 100%;
    }

    .kind,
    .status,
    .metric {
      flex: 0 1 auto;
      color: var(--ink-600);
      font-size: 0.75rem;
    }
  }

  @media (forced-colors: active) {
    .table-scroll,
    th,
    td,
    tbody tr {
      border-color: CanvasText;
    }

    .status-dot {
      border: 1px solid CanvasText;
      background: Canvas;
    }
  }
</style>
