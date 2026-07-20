<script lang="ts">
import type { ScreenSectionProps } from "../../index";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime, projection }: ScreenSectionProps = $props();
const showResponse = $derived(/response|party/i.test(section.id));
</script>
<SectionHeading {section} kicker="균형 잡힌 설명" />
<div class="known-unknown-response"><article><h3>확인된 내용</h3>{#if projection}{#each projection.fields.filter((field) => field.known) as field}<p><strong>{field.label}</strong>: {field.value}</p>{/each}{:else}<p>권위 projection을 불러오는 중입니다.</p>{/if}</article><article><h3>아직 모르는 내용</h3>{#if projection && projection.fields.some((field) => !field.known)}{#each projection.fields.filter((field) => !field.known) as field}<p>{field.label}: 확인 필요</p>{/each}{:else}<p>원자료 범위 밖의 의도와 책임은 자동으로 추정하지 않습니다.</p>{/if}</article>{#if showResponse}<article><h3>당사자 설명</h3><p>접수된 설명과 답변은 원 주장과 구분해 같은 중요도로 검토합니다.</p></article>{/if}</div>
