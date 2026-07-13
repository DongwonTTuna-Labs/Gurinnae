<script lang="ts">
import { ScreenPage } from "@gurine/ui";

let { data } = $props();
</script>

<ScreenPage screen={data.screen} runtime={data.runtime} />
