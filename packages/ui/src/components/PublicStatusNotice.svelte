<script lang="ts">
import type { PublicStatusNotice as PublicStatusNoticeViewModel } from "../public-status-notice";

let {
  notice,
  compact = false,
}: {
  notice: PublicStatusNoticeViewModel;
  compact?: boolean;
} = $props();
</script>

<p
  class="public-status-notice"
  class:compact
  data-notice-kind={notice.kind}
>
  <strong>{notice.label}</strong>
  <span>{notice.text}</span>
</p>

<style>
  .public-status-notice {
    display: flex;
    gap: 0.375rem 0.625rem;
    align-items: baseline;
    min-width: 0;
    margin: 0.375rem 0 0;
    padding: 0.375rem 0.5rem;
    border-block: 1px solid var(--paper-200);
    color: var(--ink-700);
    font-size: 0.8125rem;
    line-height: 1.45;
  }

  .public-status-notice strong {
    flex: 0 0 auto;
    color: var(--ink-900);
    font-size: 0.75rem;
  }

  .public-status-notice span {
    min-width: 0;
  }

  .public-status-notice.compact {
    display: block;
    margin-top: 0.25rem;
    padding: 0;
    border: 0;
    font-size: 0.75rem;
    line-height: 1.35;
  }

  .public-status-notice.compact strong {
    display: block;
    margin-bottom: 0.125rem;
  }
</style>
