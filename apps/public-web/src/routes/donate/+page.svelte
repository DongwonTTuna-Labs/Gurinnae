<script lang="ts">
import { ScreenPage } from "@gurine/ui";
import { withDonationAction } from "$lib/view-models/pub-035";

let { data, form } = $props();
const runtime = $derived(withDonationAction(data.runtime, form));
</script>

<ScreenPage screen={data.screen} {runtime} />
