<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import ResponseJourneySection from "./ResponseJourneySection.svelte";

let props: ScreenSectionProps = $props();
</script>

<ResponseJourneySection {...props} embedded />
