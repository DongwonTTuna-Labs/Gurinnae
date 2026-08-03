<script lang="ts">
import type { PublicStatusNotice as PublicStatusNoticeViewModel } from "../public-status-notice";
import PublicStatusNotice from "./PublicStatusNotice.svelte";

let { notice }: { notice: PublicStatusNoticeViewModel } = $props();
</script>

<div class="public-section-status-notice" role="note" aria-label="공개 상태 고지">
  <PublicStatusNotice {notice} compact />
</div>

<style>
  .public-section-status-notice {
    border-block: 1px solid var(--paper-200);
  }

  .public-section-status-notice :global(.public-status-notice.compact) {
    display: flex;
    gap: 0.375rem;
    align-items: baseline;
    margin: 0;
    padding: 0.25rem 0.5rem;
    border: 0;
  }

  .public-section-status-notice :global(.public-status-notice.compact strong) {
    display: inline;
    margin: 0;
  }
</style>
