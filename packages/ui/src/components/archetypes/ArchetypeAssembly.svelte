<script lang="ts">
import type { Component } from "svelte";
import { archetypeAssemblyFor } from "../../screen-archetype";
import type { ArchetypeAssemblyProps } from "./archetype-assembly";
import DecisionReviewAssembly from "./DecisionReviewAssembly.svelte";
import EvidenceLandingAssembly from "./EvidenceLandingAssembly.svelte";
import GuidedFormAssembly from "./GuidedFormAssembly.svelte";
import OperationsAssembly from "./OperationsAssembly.svelte";
import PolicyAssembly from "./PolicyAssembly.svelte";
import QueueAssembly from "./QueueAssembly.svelte";
import RecordAssembly from "./RecordAssembly.svelte";
import WorkspaceAssembly from "./WorkspaceAssembly.svelte";

const ASSEMBLY_COMPONENTS = {
  "evidence-landing": EvidenceLandingAssembly,
  record: RecordAssembly,
  policy: PolicyAssembly,
  "guided-form": GuidedFormAssembly,
  queue: QueueAssembly,
  workspace: WorkspaceAssembly,
  "decision-review": DecisionReviewAssembly,
  operations: OperationsAssembly,
} as const satisfies Record<
  ReturnType<typeof archetypeAssemblyFor>,
  Component<ArchetypeAssemblyProps>
>;

let {
  screen,
  runtime,
  contract,
  projection,
  skipStatus = false,
  variant = "standard",
}: ArchetypeAssemblyProps = $props();
const Assembly = $derived(
  ASSEMBLY_COMPONENTS[archetypeAssemblyFor(screen.archetype)],
);
</script>

<Assembly
  {screen}
  {runtime}
  {contract}
  {projection}
  {skipStatus}
  {variant}
/>
