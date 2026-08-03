<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import PublicDonationForm from "./PublicDonationForm.svelte";
import PublicDonationReceipt from "./PublicDonationReceipt.svelte";
import PublicDonationSummary from "./PublicDonationSummary.svelte";

let props: ScreenSectionProps = $props();
</script>

{#if props.section.id === "mode" || props.section.id === "independence"}
  <PublicDonationSummary {...props} />
{:else if props.section.id === "donation"}
  <PublicDonationForm {...props} />
{:else if props.section.id === "receipt"}
  <PublicDonationReceipt {...props} />
{/if}
