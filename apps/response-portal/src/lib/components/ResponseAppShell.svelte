<script lang="ts">
import type { Snippet } from "svelte";
import { page } from "$app/state";

let { children }: { children: Snippet } = $props();
const actionMessage = $derived(messageOf(page.form));

function messageOf(value: unknown): string | undefined {
  if (typeof value !== "object" || value === null || !("message" in value))
    return undefined;
  return typeof value.message === "string" ? value.message : undefined;
}
</script>

<a class="skip-link" href="#main-content">본문으로 건너뛰기</a>
{#if actionMessage}
  <div class="action-error-host"><div class="error-summary" role="alert" tabindex="-1"><h2>요청을 완료하지 못했습니다</h2><p><a data-error-target href="#main-content">오류 요약으로 이동</a></p><p>{actionMessage}</p></div></div>
{/if}
{@render children()}

<style>.action-error-host { width: min(100% - 32px, 960px); margin: 0 auto; }</style>
