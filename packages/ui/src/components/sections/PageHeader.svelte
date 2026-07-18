<script lang="ts">import type { ScreenSectionProps } from "../../index"; import AuthorityRecordSection from "./AuthorityRecordSection.svelte"; let props: ScreenSectionProps = $props();</script>
<AuthorityRecordSection {...props} kicker="대상과 현재 상태" />
