<script lang="ts">
import { firstValue, semanticRecords } from "../../data";
import type { ScreenSectionProps } from "../../index";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime }: ScreenSectionProps = $props();
const record = $derived(semanticRecords(runtime)[0]?.record ?? {});
</script>
<SectionHeading {section} kicker="현재 상태" />
<div class="status-revision-grid">
  <p><span>상태</span><strong>{firstValue(record, ["status", "state", "publicState", "publicationState"])}</strong></p>
  <p><span>리비전</span><strong>{firstValue(record, ["revision", "version", "latestRevision"])}</strong></p>
  <p><span>기준 시각</span><strong>{firstValue(record, ["asOf", "updatedAt", "publishedAt", "occurredAt"])}</strong></p>
</div>
