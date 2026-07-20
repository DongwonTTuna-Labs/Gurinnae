<script lang="ts">
import { ScreenPage } from "@gurine/ui";

let { data, form } = $props();
const runtime = $derived({
  ...data.runtime,
  formData: {
    ...data.runtime.formData,
    ...(form?.formData ? { submitted: form.formData } : {}),
  },
});
</script>

<ScreenPage screen={data.screen} runtime={runtime} />
