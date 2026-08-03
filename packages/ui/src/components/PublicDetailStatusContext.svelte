<script lang="ts">
import type { PublicDetailStatusContext as PublicDetailStatusContextViewModel } from "../public-status-notice";
import PublicStatusNotice from "./PublicStatusNotice.svelte";

let {
  context,
  showSubject = true,
}: {
  context: PublicDetailStatusContextViewModel;
  showSubject?: boolean;
} = $props();
</script>

<div
  class="public-detail-status-context"
  data-public-subject={context.subject.text}
  data-public-status={context.status?.text}
>
  {#if showSubject || context.status}
    <dl aria-label="공개 대상과 상태">
      {#if showSubject}
        <div><dt>{context.subject.label}</dt><dd>{context.subject.text}</dd></div>
      {/if}
      {#if context.status}
        <div><dt>{context.status.label}</dt><dd>{context.status.text}</dd></div>
      {/if}
    </dl>
  {/if}
  <PublicStatusNotice notice={context.notice} />
</div>

<style>
  .public-detail-status-context {
    min-width: 0;
    margin-block: 0;
    border-block: 1px solid var(--paper-200);
  }

  dl {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(10rem, 1fr));
    gap: 1px;
    margin: 0;
    background: var(--paper-200);
  }

  dl > div {
    display: grid;
    grid-template-columns: max-content minmax(0, 1fr);
    gap: 0.5rem;
    min-width: 0;
    padding: 0.25rem 0.5rem;
    background: var(--paper-0);
  }

  dt {
    color: var(--ink-500);
    font-size: 0.75rem;
    font-weight: 650;
  }

  dd {
    min-width: 0;
    margin: 0;
    color: var(--ink-900);
    font-size: 0.8125rem;
    font-weight: 650;
    overflow-wrap: anywhere;
  }

  :global(.public-detail-status-context > .public-status-notice) {
    margin: 0;
    padding-block: 0.25rem;
    border: 0;
  }
</style>
