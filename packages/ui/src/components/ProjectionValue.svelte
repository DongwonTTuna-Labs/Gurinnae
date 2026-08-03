<script lang="ts">
import type { ProjectionValue as ProjectionValueType } from "../projection-value";
import { presentProjectionValue } from "../projection-value";
import ProjectionValue from "./ProjectionValue.svelte";

let {
  name,
  label,
  value,
  href = null,
}: {
  name: string;
  label: string;
  value: ProjectionValueType | null;
  href?: string | null;
} = $props();

const presented = $derived(presentProjectionValue(name, value));
const listValue = $derived(
  value !== null && typeof value === "object" && value.kind === "list"
    ? value
    : null,
);
const recordValue = $derived(
  value !== null && typeof value === "object" && value.kind === "record"
    ? value
    : null,
);
let copiedValue = $state<string | null>(null);
let copyFailed = $state(false);

async function copyFullValue(fullValue: string): Promise<void> {
  copyFailed = false;
  if (!navigator.clipboard) {
    copyFailed = true;
    return;
  }
  try {
    await navigator.clipboard.writeText(fullValue);
    copiedValue = fullValue;
  } catch {
    copyFailed = true;
  }
}
</script>

{#if presented?.kind === "scalar"}
  <span class="projection-scalar" data-value-kind={presented.valueKind}>
    {#if href}<a {href} title={presented.title}>{presented.text}</a>
    {:else}<span title={presented.title}>{presented.text}</span>{/if}
    {#if presented.secondary}<small>{presented.secondary}</small>{/if}
    {#if presented.copyText}
      <button type="button" class="copy-value" onclick={() => copyFullValue(presented.copyText ?? "")}>
        {copyFailed ? "복사 실패" : copiedValue === presented.copyText ? "복사됨" : "복사"}
        <span class="sr-only"> · {label} 전체값</span>
      </button>
    {/if}
  </span>
{:else if listValue}
  <ul class="projection-list">
    {#each listValue.items as item, index (`${name}-${index}`)}
      <li><ProjectionValue name={name} {label} value={item} /></li>
    {/each}
    {#if listValue.omittedCount > 0}<li class="omitted">외 {listValue.omittedCount}건</li>{/if}
  </ul>
{:else if recordValue}
  <dl class="projection-record">
    {#each recordValue.entries as entry (entry.name)}
      <div>
        <dt>{entry.label}</dt>
        <dd><ProjectionValue name={entry.name} label={entry.label} value={entry.value} /></dd>
      </div>
    {/each}
    {#if recordValue.omittedCount > 0}
      <div class="omitted"><dt>추가 항목</dt><dd>외 {recordValue.omittedCount}개</dd></div>
    {/if}
  </dl>
{/if}

<style>
  .projection-scalar {
    display: inline-flex;
    flex-wrap: wrap;
    gap: 0.25rem 0.5rem;
    align-items: baseline;
    min-width: 0;
    max-width: 100%;
  }

  .projection-scalar > span,
  .projection-scalar > a {
    min-width: 0;
    overflow-wrap: anywhere;
  }

  .projection-scalar small {
    color: var(--ink-500);
    font-size: 0.75rem;
    white-space: nowrap;
  }

  .copy-value {
    min-height: 1.75rem;
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

  .projection-list {
    display: grid;
    gap: 0.25rem;
    margin: 0;
    padding: 0;
    list-style: none;
  }

  .projection-list > li {
    min-width: 0;
    padding-block: 0.125rem;
    border-bottom: 1px solid var(--paper-200);
  }

  .projection-list > li:last-child {
    border-bottom: 0;
  }

  .projection-record {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 14rem), 1fr));
    gap: 1px;
    margin: 0;
    background: var(--paper-200);
  }

  .projection-record > div {
    display: grid;
    grid-template-columns: minmax(6rem, 38%) minmax(0, 1fr);
    gap: 0.5rem;
    min-width: 0;
    padding: 0.375rem 0.5rem;
    background: var(--paper-0);
  }

  .projection-record dt {
    color: var(--ink-500);
    font-size: 0.75rem;
    font-weight: 650;
  }

  .projection-record dd {
    min-width: 0;
    margin: 0;
  }

  .omitted {
    color: var(--ink-500);
    font-size: 0.75rem;
  }

  @media (max-width: 620px) {
    .projection-record,
    .projection-record > div {
      grid-template-columns: minmax(0, 1fr);
    }
  }
</style>
