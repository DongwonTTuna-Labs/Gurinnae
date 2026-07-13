<script lang="ts">
import type { ScreenSectionProps } from "../index";
import AccessManagementPanel from "./sections/AccessManagementPanel.svelte";
import AgentSuggestionPanel from "./sections/AgentSuggestionPanel.svelte";
import ClaimWorkbench from "./sections/ClaimWorkbench.svelte";
import ComparisonWorkbench from "./sections/ComparisonWorkbench.svelte";
import CoverageStatement from "./sections/CoverageStatement.svelte";
import DataCollection from "./sections/DataCollection.svelte";
import DecisionReviewPanel from "./sections/DecisionReviewPanel.svelte";
import EvidenceLedger from "./sections/EvidenceLedger.svelte";
import GuidedFormSection from "./sections/GuidedFormSection.svelte";
import KnownUnknownResponse from "./sections/KnownUnknownResponse.svelte";
import LongFormArticle from "./sections/LongFormArticle.svelte";
import OperationsStatusPanel from "./sections/OperationsStatusPanel.svelte";
import RevisionAndCorrectionPanel from "./sections/RevisionAndCorrectionPanel.svelte";
import RevisionTimeline from "./sections/RevisionTimeline.svelte";
import SignalTriagePanel from "./sections/SignalTriagePanel.svelte";
import StatusAndRevisionHeader from "./sections/StatusAndRevisionHeader.svelte";
import StructuredContentSection from "./sections/StructuredContentSection.svelte";
import UnifiedSearch from "./sections/UnifiedSearch.svelte";

let props: ScreenSectionProps = $props();
</script>

{#if props.section.component === "AccessManagementPanel"}<AccessManagementPanel {...props} />
{:else if props.section.component === "AgentSuggestionPanel"}<AgentSuggestionPanel {...props} />
{:else if props.section.component === "ClaimWorkbench"}<ClaimWorkbench {...props} />
{:else if props.section.component === "ComparisonWorkbench"}<ComparisonWorkbench {...props} />
{:else if props.section.component === "CoverageStatement"}<CoverageStatement {...props} />
{:else if props.section.component === "DataCollection"}<DataCollection {...props} />
{:else if props.section.component === "DecisionReviewPanel"}<DecisionReviewPanel {...props} />
{:else if props.section.component === "EvidenceLedger"}<EvidenceLedger {...props} />
{:else if props.section.component === "GuidedFormSection"}<GuidedFormSection {...props} />
{:else if props.section.component === "KnownUnknownResponse"}<KnownUnknownResponse {...props} />
{:else if props.section.component === "LongFormArticle"}<LongFormArticle {...props} />
{:else if props.section.component === "OperationsStatusPanel"}<OperationsStatusPanel {...props} />
{:else if props.section.component === "RevisionAndCorrectionPanel"}<RevisionAndCorrectionPanel {...props} />
{:else if props.section.component === "RevisionTimeline"}<RevisionTimeline {...props} />
{:else if props.section.component === "SignalTriagePanel"}<SignalTriagePanel {...props} />
{:else if props.section.component === "StatusAndRevisionHeader"}<StatusAndRevisionHeader {...props} />
{:else if props.section.component === "StructuredContentSection"}<StructuredContentSection {...props} />
{:else if props.section.component === "UnifiedSearch"}<UnifiedSearch {...props} />
{:else}<StructuredContentSection {...props} />{/if}
