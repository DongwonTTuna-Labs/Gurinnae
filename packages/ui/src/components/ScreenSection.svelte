<script lang="ts">
import type { ScreenSectionProps } from "../index";
import { typedScreenViewModel } from "../screen-contract";
import AccessManagementPanel from "./sections/AccessManagementPanel.svelte";
import AgentAnalysisProjection from "./sections/AgentAnalysisProjection.svelte";
import AgentSuggestionPanel from "./sections/AgentSuggestionPanel.svelte";
import BusinessHealthPanel from "./sections/BusinessHealthPanel.svelte";
import CheckAnswers from "./sections/CheckAnswers.svelte";
import ClaimWorkbench from "./sections/ClaimWorkbench.svelte";
import ComparisonWorkbench from "./sections/ComparisonWorkbench.svelte";
import CoverageStatement from "./sections/CoverageStatement.svelte";
import DataCollection from "./sections/DataCollection.svelte";
import DecisionReceipt from "./sections/DecisionReceipt.svelte";
import DecisionReviewPanel from "./sections/DecisionReviewPanel.svelte";
import EvidenceLedger from "./sections/EvidenceLedger.svelte";
import FileUploadQueue from "./sections/FileUploadQueue.svelte";
import GateChecklist from "./sections/GateChecklist.svelte";
import GuidedFormSection from "./sections/GuidedFormSection.svelte";
import KnownUnknownResponse from "./sections/KnownUnknownResponse.svelte";
import LegalContentSection from "./sections/LegalContentSection.svelte";
import LongFormArticle from "./sections/LongFormArticle.svelte";
import MetricWithContext from "./sections/MetricWithContext.svelte";
import NotificationBanner from "./sections/NotificationBanner.svelte";
import OmnichannelApprovalPanel from "./sections/OmnichannelApprovalPanel.svelte";
import OperationsStatusPanel from "./sections/OperationsStatusPanel.svelte";
import PageHeader from "./sections/PageHeader.svelte";
import PublicCorrectionRequestForm from "./sections/PublicCorrectionRequestForm.svelte";
import PublicCorrections from "./sections/PublicCorrections.svelte";
import PublicDatasetExportForm from "./sections/PublicDatasetExportForm.svelte";
import PublicLedger from "./sections/PublicLedger.svelte";
import PublicSubscriptionForm from "./sections/PublicSubscriptionForm.svelte";
import RelatedPublicCases from "./sections/RelatedPublicCases.svelte";
import ResponseJourneySection from "./sections/ResponseJourneySection.svelte";
import RevisionAndCorrectionPanel from "./sections/RevisionAndCorrectionPanel.svelte";
import RevisionTimeline from "./sections/RevisionTimeline.svelte";
import SaveStatus from "./sections/SaveStatus.svelte";
import SectionHeading from "./sections/SectionHeading.svelte";
import SemanticSection from "./sections/SemanticSection.svelte";
import SensitiveDataNotice from "./sections/SensitiveDataNotice.svelte";
import SignalTriagePanel from "./sections/SignalTriagePanel.svelte";
import StatusAndRevisionHeader from "./sections/StatusAndRevisionHeader.svelte";
import StepIndicator from "./sections/StepIndicator.svelte";
import StructuredContentSection from "./sections/StructuredContentSection.svelte";
import UnifiedSearch from "./sections/UnifiedSearch.svelte";

let props: ScreenSectionProps = $props();
const contract = $derived(typedScreenViewModel(props.screen));
const publicLedgerSections: Readonly<Record<string, string>> = {
  "PUB-001": "recent",
  "PUB-002": "results",
  "PUB-003": "results",
  "PUB-007": "results",
  "PUB-009": "results",
  "PUB-011": "results",
  "PUB-015": "sources",
  "PUB-016": "list",
  "PUB-018": "records",
  "PUB-034": "impact",
};
const publicLedgerSection = $derived(
  publicLedgerSections[props.screen.id] === props.section.id,
);
const hasValidationError = $derived(
  ["validation-error", "error", "conflict"].includes(props.runtime.state),
);
const actionLabel = (actionId: string, fallback: string) =>
  props.screen.actions.find((action) => action.id === actionId)?.label ??
  fallback;
</script>

{#if (props.screen.id === "CAS-010" || (props.screen.id === "CAS-011" && props.section.id !== "decisions"))}<AgentAnalysisProjection {...props} />
{:else if contract.journey === "J-03" && (props.screen.id === "RSP-005" || props.screen.id === "RSP-006") }<ResponseJourneySection {...props} />
{:else if publicLedgerSection}<PublicLedger {...props} />
{:else if props.screen.id === "PUB-001" && props.section.id === "corrections"}<PublicCorrections {...props} />
{:else if ((props.screen.id === "PUB-008" || props.screen.id === "PUB-010") && props.section.id === "cases") || (props.screen.id === "PUB-012" && props.section.id === "related")}<RelatedPublicCases {...props} />
{:else if props.screen.id === "PUB-031" || props.screen.id === "PUB-032"}<LegalContentSection {...props} />
{:else if props.screen.id === "PUB-029" && props.section.id === "email"}<PublicSubscriptionForm {...props} />
{:else if props.screen.id === "PUB-020" && props.section.id === "datasets"}
  <SectionHeading section={props.section} kicker="데이터 내려받기" />
  <PublicDatasetExportForm
    fields={props.runtime.forms["download-dataset"] ?? []}
    datasets={props.runtime.publicDatasets ?? []}
    actionLabel={actionLabel("download-dataset", "데이터 내려받기")}
    search={props.runtime.search ?? ""}
    csrfToken={props.runtime.csrfToken}
    idempotencyKey={props.runtime.idempotencyKeys?.["download-dataset"]}
    botChallenge={props.runtime.botChallenge}
    {hasValidationError}
  />
{:else if props.screen.id === "PUB-027" && props.section.id === "issue"}
  <SectionHeading section={props.section} kicker="정정 요청" />
  <PublicCorrectionRequestForm
    fields={props.runtime.forms["save-draft"] ?? []}
    actionLabel={actionLabel("save-draft", "임시 저장")}
    search={props.runtime.search ?? ""}
    csrfToken={props.runtime.csrfToken}
    idempotencyKey={props.runtime.idempotencyKeys?.["save-draft"]}
    botChallenge={props.runtime.botChallenge}
    {hasValidationError}
  />
{:else if props.section.component === "BusinessHealthPanel"}<BusinessHealthPanel {...props} />
{:else if props.section.component === "OmnichannelApprovalPanel"}<OmnichannelApprovalPanel {...props} />
{:else if props.section.component === "CheckAnswers"}<CheckAnswers {...props} />
{:else if props.section.component === "AccessManagementPanel"}<AccessManagementPanel {...props} />
{:else if props.section.component === "PageHeader"}<PageHeader {...props} />
{:else if props.section.component === "SensitiveDataNotice"}<SensitiveDataNotice {...props} />
{:else if props.section.component === "StepIndicator"}<StepIndicator {...props} />
{:else if props.section.component === "SaveStatus"}<SaveStatus {...props} />
{:else if props.section.component === "NotificationBanner"}<NotificationBanner {...props} />
{:else if props.section.component === "FileUploadQueue"}<FileUploadQueue {...props} />
{:else if props.section.component === "DecisionReceipt"}<DecisionReceipt {...props} />
{:else if props.section.component === "GateChecklist"}<GateChecklist {...props} />
{:else if props.section.component === "MetricWithContext"}<MetricWithContext {...props} />
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
{:else}<SemanticSection {...props} />{/if}
