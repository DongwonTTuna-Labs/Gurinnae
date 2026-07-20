<script lang="ts">
import type { Snippet } from "svelte";
import { tick } from "svelte";
import { page } from "$app/state";

let { children }: { children: Snippet } = $props();
const actionMessage = $derived(messageOf(page.form));
$effect(() => {
  if (actionMessage && typeof document !== "undefined") {
    void tick().then(() => {
      const summary = document.querySelector<HTMLElement>(
        ".action-error-host .error-summary",
      );
      const target = findErrorField(actionMessage);
      if (summary && target) {
        if (!target.id) target.id = "action-first-error-field";
        summary
          .querySelector<HTMLAnchorElement>("[data-error-target]")
          ?.setAttribute("href", `#${target.id}`);
      }
      summary?.focus();
    });
  }
});

function messageOf(value: unknown): string | undefined {
  if (typeof value !== "object" || value === null || !("message" in value))
    return undefined;
  return typeof value.message === "string" ? value.message : undefined;
}

function findErrorField(message: string): HTMLElement | null {
  const normalized = message.toLocaleLowerCase();
  for (const label of document.querySelectorAll<HTMLLabelElement>(
    "main label",
  )) {
    if (
      !normalized.includes(label.textContent?.trim().toLocaleLowerCase() ?? "")
    )
      continue;
    const id = label.htmlFor;
    const control = id
      ? document.getElementById(id)
      : label.querySelector<HTMLElement>("input, textarea, select");
    if (control) return control;
  }
  return document.querySelector<HTMLElement>(
    "main form input:not([type='hidden']), main form textarea, main form select",
  );
}
</script>

<a class="skip-link" href="#main-content">본문으로 건너뛰기</a>
{#if actionMessage}
  <div class="action-error-host"><div class="error-summary" role="alert" tabindex="-1"><h2>요청을 완료하지 못했습니다</h2><p><a data-error-target href="#main-content">오류가 있는 입력 항목으로 이동</a></p><p>{actionMessage}</p></div></div>
{/if}
{@render children()}

<style>.action-error-host { width: min(100% - 32px, 960px); margin: 0 auto; }</style>
