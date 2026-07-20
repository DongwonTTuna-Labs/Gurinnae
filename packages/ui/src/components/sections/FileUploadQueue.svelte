<script lang="ts">import type { ScreenSectionProps } from "../../index";
import AuthorityRecordSection from "./AuthorityRecordSection.svelte";

let props: ScreenSectionProps = $props();
</script>
<AuthorityRecordSection {...props} kicker="첨부자료 상태" />
