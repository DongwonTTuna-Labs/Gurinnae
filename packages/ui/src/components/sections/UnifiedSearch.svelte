<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import SectionHeading from "./SectionHeading.svelte";

let { section, screen }: ScreenSectionProps = $props();
</script>
<SectionHeading {section} kicker="검색" />
<form class="unified-search" method="GET" action={screen.route === "/" ? "/search" : screen.route} role="search">
  <label for={`${section.test_id}-query`}>기관·업체·계약·사건 검색</label>
  <div><input id={`${section.test_id}-query`} name="q" type="search" autocomplete="off" /><button type="submit">검색</button></div>
</form>
