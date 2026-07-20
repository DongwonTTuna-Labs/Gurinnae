//! Additive v13.1 HTTP surface.
//!
//! This module deliberately keeps additive operations in a separate, closed
//! catalog.  A service must opt in to one of the two arrays below; there is no
//! catch-all route and an operation that is not present in the catalog cannot
//! be dispatched.

use crate::OperationSpec;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

macro_rules! operation {
    ($id:literal, $api:literal, $method:literal, $path:literal, $auth:literal,
     $cap:literal, $assurance:tt, $kind:tt, $status:literal,
     $response:expr) => {
        OperationSpec {
            id: $id,
            api: $api,
            method: $method,
            path: $path,
            auth: $auth,
            capability: $cap,
            idempotency_required: operation_idempotency!($kind),
            assurance_level: $assurance,
            step_up_required: operation_step_up!($assurance),
            operation_kind: $kind,
            success_status: $status,
            media_type: "application/json",
            response_json: $response,
        }
    };
}

macro_rules! operation_idempotency {
    ("COMMAND") => {
        true
    };
    ("QUERY") => {
        false
    };
}

macro_rules! operation_step_up {
    ("STEP_UP") => {
        true
    };
    ($other:literal) => {
        false
    };
}

mod control_catalog;
pub use control_catalog::CONTROL_OPERATIONS;
mod bff_catalog;
pub use bff_catalog::{
    IDENTITY_OPERATIONS, PRIVATE_COMMUNICATION_OPERATIONS, SUBMISSION_OPERATIONS,
};

const COMMAND_RECEIPT: &str = r#"{"operationId":"","requestId":"00000000-0000-4000-8000-000000000001","status":"ACCEPTED","aggregateId":"00000000-0000-4000-8000-000000000001","aggregateVersion":1,"auditEventId":"00000000-0000-4000-8000-000000000001","acceptedAt":"2026-07-12T00:00:00.000000Z","receiptDigest":"0000000000000000000000000000000000000000000000000000000000000000","emittedEventIds":[],"idempotencyReplay":false,"links":[]}"#;
const QUERY_BODY: &str = "{}";

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CommandReceiptV1 {
    pub operation_id: String,
    pub request_id: String,
    pub status: String,
    pub aggregate_id: String,
    pub aggregate_version: i64,
    pub audit_event_id: String,
    pub accepted_at: String,
    pub receipt_digest: String,
    pub emitted_event_ids: Vec<String>,
    pub idempotency_replay: bool,
    pub links: Vec<LinkV1>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct LinkV1 {
    pub rel: String,
    pub href: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct AddendumProblemDetailsV1 {
    pub code: String,
    pub title: String,
    pub status: u16,
    pub request_id: String,
    pub detail: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CreateResponseAppealRequestV1 {
    pub expected_receipt_version: i64,
    pub reason_code: String,
    pub requested_outcome: String,
    pub statement: String,
    pub supporting_attachment_ids: Vec<String>,
    pub attestation: bool,
    pub privacy_consent: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct GetResponseAppealRequestV1 {
    pub appeal_id: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct RequestCommunicationEndpointLinkRequestV1 {
    pub contract_version: String,
    pub endpoint: Value,
    pub linking_consent: Value,
    pub expected_profile_version: i64,
    pub abuse_proof: Value,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct VerifyCommunicationEndpointLinkRequestV1 {
    pub challenge_id: String,
    pub proof: Value,
    pub expected_profile_version: i64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct UnlinkCommunicationEndpointRequestV1 {
    pub endpoint_id: String,
    pub expected_endpoint_version: i64,
    pub expected_profile_version: i64,
    pub reason_code: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CreatePrivacyRequestRequestV1 {
    pub request_type: String,
    pub subject_identity_proof: Value,
    pub jurisdiction: String,
    pub scope: Value,
    pub contact_endpoint: Value,
    pub statement: String,
    pub attestation: bool,
    pub privacy_consent: bool,
    pub abuse_proof: Value,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ExchangePrivacyRequestReceiptTokenRequestV1 {
    pub token: String,
    pub proof: Value,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct GetPrivacyRequestRequestV1;

/// Canonical request/response schema names and persistence owner links.  The
/// table/function names are intentionally explicit; callers cannot fall back
/// to a generic JSON repository when an operation is missing from this map.
pub fn request_schema(id: &str) -> Option<&'static str> {
    Some(match id {
        "listActionApprovalQueue" => "ListActionApprovalQueueRequestV1",
        "createActionProposal" => "CreateActionProposalRequestV1",
        "getActionProposal" => "GetActionProposalRequestV1",
        "updateActionDraft" => "UpdateActionDraftRequestV1",
        "previewActionDraft" => "PreviewActionDraftRequestV1",
        "submitActionForReview" => "SubmitActionForReviewRequestV1",
        "claimActionReview" => "ClaimActionReviewRequestV1",
        "submitActionDecision" => "SubmitActionDecisionRequestV1",
        "getActionExecutionReceipt" => "GetActionExecutionReceiptRequestV1",
        "cancelActionExecution" => "CancelActionExecutionRequestV1",
        "retryActionExecution" => "RetryActionExecutionRequestV1",
        "releaseLegalHold" => "ReleaseLegalHoldRequestV1",
        "createResponseAppeal" => "CreateResponseAppealRequestV1",
        "getResponseAppeal" => "GetResponseAppealRequestV1",
        "getCommunicationDeliveryReceipt" => "GetCommunicationDeliveryReceiptRequestV1",
        "reconcileCommunicationDelivery" => "ReconcileCommunicationDeliveryRequestV1",
        "cancelCommunicationDelivery" => "CancelCommunicationDeliveryRequestV1",
        "getIncident" => "GetIncidentRequestV1",
        "triageIncident" => "TriageIncidentRequestV1",
        "containIncident" => "ContainIncidentRequestV1",
        "startIncidentRecovery" => "StartIncidentRecoveryRequestV1",
        "resolveIncident" => "ResolveIncidentRequestV1",
        "closeIncidentPostmortem" => "CloseIncidentPostmortemRequestV1",
        "listResponseAppeals" => "ListResponseAppealsRequestV1",
        "getResponseAppealWorkspace" => "GetResponseAppealWorkspaceRequestV1",
        "transitionResponseAppeal" => "TransitionResponseAppealRequestV1",
        "decideResponseExtension" => "DecideResponseExtensionRequestV1",
        "listRetentionRequests" => "ListRetentionRequestsRequestV1",
        "getRetentionRequest" => "GetRetentionRequestRequestV1",
        "transitionRetentionRequest" => "TransitionRetentionRequestRequestV1",
        "listRecordClassSchedules" => "ListRecordClassSchedulesRequestV1",
        "requestCommunicationEndpointLink" => "RequestCommunicationEndpointLinkRequestV1",
        "verifyCommunicationEndpointLink" => "VerifyCommunicationEndpointLinkRequestV1",
        "unlinkCommunicationEndpoint" => "UnlinkCommunicationEndpointRequestV1",
        "createPrivacyRequest" => "CreatePrivacyRequestRequestV1",
        "exchangePrivacyRequestReceiptToken" => "ExchangePrivacyRequestReceiptTokenRequestV1",
        "getPrivacyRequest" => "GetPrivacyRequestRequestV1",
        "declareConflict" => "DeclareConflictRequestV1",
        "withdrawConflict" => "WithdrawConflictRequestV1",
        "withdrawActionProposal" => "WithdrawActionProposalRequestV1",
        "withdrawActionDecision" => "WithdrawActionDecisionRequestV1",
        "promoteResearchArtifactToEvidence" => "PromoteResearchArtifactRequestV1",
        "cancelAgentRun" => "CancelAgentRunRequestV2",
        "decideJourneyHandoff" => "DecideJourneyHandoffRequestV1",
        _ => return None,
    })
}

pub fn response_schema(id: &str) -> Option<&'static str> {
    Some(match id {
        "listActionApprovalQueue" => "ActionApprovalQueuePageV1",
        "createActionProposal" | "updateActionDraft" | "withdrawActionProposal" => {
            "ActionProposalReceiptV1"
        }
        "previewActionDraft" => "ActionPreviewReceiptV1",
        "submitActionForReview" => "ActionReviewRequestedReceiptV1",
        "claimActionReview" => "ActionReviewClaimedReceiptV1",
        "submitActionDecision" | "withdrawActionDecision" => "ActionDecisionReceiptV1",
        "getActionProposal" => "ActionProposalDetailV1",
        "getActionExecutionReceipt" => "ActionExecutionReceiptChainV1",
        "cancelActionExecution" | "retryActionExecution" => "ActionExecutionMutationReceiptV1",
        "releaseLegalHold" => "LegalHoldReleaseReceiptV1",
        "createResponseAppeal" => "ResponseAppealReceiptV1",
        "getResponseAppeal" => "ResponseAppealPublicStatusV1",
        "getCommunicationDeliveryReceipt" => "CommunicationDeliveryReceiptViewV1",
        "reconcileCommunicationDelivery" | "cancelCommunicationDelivery" => {
            "CommunicationDeliveryMutationReceiptV1"
        }
        "getIncident"
        | "triageIncident"
        | "containIncident"
        | "startIncidentRecovery"
        | "resolveIncident"
        | "closeIncidentPostmortem" => "IncidentTransitionReceiptV1",
        "listResponseAppeals" => "ResponseAppealQueuePageV1",
        "getResponseAppealWorkspace" => "ResponseAppealWorkspaceV1",
        "transitionResponseAppeal" => "ResponseAppealDecisionReceiptV1",
        "decideResponseExtension" => "ResponseExtensionDecisionReceiptV1",
        "listRetentionRequests" => "RetentionRequestQueuePageV1",
        "getRetentionRequest" => "RetentionRequestWorkspaceV1",
        "transitionRetentionRequest" => "RetentionRequestDecisionReceiptV1",
        "listRecordClassSchedules" => "RecordClassSchedulePageV1",
        "requestCommunicationEndpointLink" => "CommunicationEndpointLinkRequestedReceiptV1",
        "verifyCommunicationEndpointLink" => "CommunicationEndpointVerifiedReceiptV1",
        "unlinkCommunicationEndpoint" => "CommunicationEndpointUnlinkedReceiptV1",
        "createPrivacyRequest" => "PrivacyRequestReceiptV1",
        "exchangePrivacyRequestReceiptToken" => "PrivacyRequestSessionReceiptV1",
        "getPrivacyRequest" => "PrivacyRequestPublicStatusV1",
        "declareConflict" | "withdrawConflict" => "ConflictDeclarationReceiptV1",
        "promoteResearchArtifactToEvidence" => "PromoteResearchArtifactReceiptV1",
        "cancelAgentRun" => "AgentRunControlReceiptV2",
        "decideJourneyHandoff" => "JourneyHandoffDecisionReceiptV1",
        _ => return None,
    })
}

pub fn persistence_owner(id: &str) -> Option<&'static str> {
    Some(match id {
        id if id.starts_with("listAction")
            || id.starts_with("createAction")
            || id.contains("ActionDraft")
            || id.contains("ActionForReview")
            || id.contains("ActionReview")
            || id.contains("ActionDecision")
            || id.contains("ActionProposal") =>
        {
            "ops.action_proposals"
        }
        id if id.contains("Execution") => "ops.execution_receipts",
        id if id.contains("CommunicationDelivery") => "ops.outbound_delivery_receipts",
        id if id.contains("Incident") => "ops.incident_events",
        id if id.contains("Appeal") => "intake.appeals",
        id if id.contains("ResponseExtension") => "editorial.response_extension_decisions",
        id if id.contains("Retention") || id == "releaseLegalHold" => {
            "ops.retention_request_decisions"
        }
        id if id.contains("CommunicationEndpoint") => "intake.communication_endpoint_link_events",
        id if id.contains("PrivacyRequest") => "intake.privacy_requests",
        id if id.contains("Conflict") => "editorial.conflict_declarations",
        "promoteResearchArtifactToEvidence" => "raw.research_artifact_promotions",
        "cancelAgentRun" => "ops.agent_run_control_receipts",
        "decideJourneyHandoff" => "ops.journey_transition_receipts",
        _ => return None,
    })
}

pub fn control_operation(id: &str) -> Option<OperationSpec> {
    CONTROL_OPERATIONS
        .iter()
        .find(|operation| operation.id == id)
        .copied()
}

pub fn submission_operation(id: &str) -> Option<OperationSpec> {
    SUBMISSION_OPERATIONS
        .iter()
        .find(|operation| operation.id == id)
        .copied()
}

pub fn is_control_operation(id: &str) -> bool {
    control_operation(id).is_some()
        || PRIVATE_CONTROL_OPERATIONS
            .iter()
            .any(|operation| operation.id == id)
}

pub fn private_control_operation(id: &str) -> Option<OperationSpec> {
    PRIVATE_CONTROL_OPERATIONS
        .iter()
        .find(|operation| operation.id == id)
        .copied()
}

pub fn is_submission_operation(id: &str) -> bool {
    submission_operation(id).is_some()
}

pub fn operations() -> impl Iterator<Item = &'static OperationSpec> {
    CONTROL_OPERATIONS
        .iter()
        .chain(SUBMISSION_OPERATIONS.iter())
        .chain(IDENTITY_OPERATIONS.iter())
        .chain(PRIVATE_CONTROL_OPERATIONS.iter())
}

/// Validate the closed top-level shape of an additive control command. Nested
/// values are handed to their domain aggregate validators; this boundary only
/// prevents undocumented fields and missing command discriminators.
#[rustfmt::skip]
const CONTROL_REQUIRED_FIELDS: &[(&str, &[&str])] = &[
    ("createActionProposal", &["actionKind", "origin", "draft", "rationale", "expiresAt"]),
    ("updateActionDraft", &["proposalId", "expectedVersion", "expectedContentDigest", "draft", "rationale", "expiresAt"]),
    ("previewActionDraft", &["proposalId", "expectedVersion", "expectedContentDigest"]),
    ("submitActionForReview", &["proposalId", "expectedVersion", "expectedContentDigest", "previewId", "previewDigest"]),
    ("claimActionReview", &["proposalId", "assignmentId", "expectedProposalVersion", "expectedAssignmentVersion", "expectedApprovalDigest"]),
    ("submitActionDecision", &["proposalId", "actionKind", "assignmentId", "expectedProposalVersion", "expectedAssignmentVersion", "expectedApprovalDigest", "decision"]),
    ("cancelActionExecution", &["executionId", "expectedGeneration", "expectedStateVersion", "reasonCode", "reasonNote"]),
    ("retryActionExecution", &["executionId", "actionKind", "expectedGeneration", "expectedStateVersion", "safeRetryProof", "reasonCode", "reasonNote"]),
    ("releaseLegalHold", &["holdId", "caseId", "reviewSnapshotId", "expectedReleaseSequence", "expectedCaseVersion", "releaseScopeAtoms", "affectedIds", "releaseAuthorityReference", "reasonCode", "reason"]),
    ("reconcileCommunicationDelivery", &["deliveryId", "expectedVersion", "evidence", "resolution", "safeRetryProof", "reason"]),
    ("cancelCommunicationDelivery", &["deliveryId", "expectedVersion", "reasonCode", "reason"]),
    ("triageIncident", &["incidentId", "expectedVersion", "severity", "affectedCapabilities", "ownerUserId", "commanderUserId", "nextUpdateAt", "impact", "evidenceRefs", "reasonCode", "reason"]),
    ("containIncident", &["incidentId", "expectedVersion", "containmentActions", "residualImpact", "reconciliationPlan", "nextUpdateAt", "switchReceiptIds", "cancellationReceiptIds", "evidenceRefs", "reasonCode", "reason"]),
    ("startIncidentRecovery", &["incidentId", "expectedVersion", "recoveryPlan", "rollbackPlan", "recoveryOwnerUserId", "validationEvidenceRefs", "evidenceRefs", "reasonCode", "reason"]),
    ("resolveIncident", &["incidentId", "expectedVersion", "restoredSliReceiptIds", "reconciliationReceiptIds", "resolutionSummary", "approverUserId", "evidenceRefs", "reasonCode", "reason"]),
    ("closeIncidentPostmortem", &["incidentId", "expectedVersion", "rootCause", "contributingFactors", "actionItems", "postmortemDigest", "reviewerUserId", "evidenceRefs", "reasonCode", "reason"]),
    ("transitionResponseAppeal", &["appealId", "expectedDecisionSequence", "transition", "reasonCode", "reason", "evidenceReceiptIds", "task"]),
    ("decideResponseExtension", &["extensionRequestId", "expectedVersion", "decision", "reasonCode", "reason", "calendarVersionId", "newDueAt"]),
    ("transitionRetentionRequest", &["retentionRequestId", "expectedDecisionVersion", "transition", "reasonCode", "reason", "inventorySnapshotDigest", "holdCoverageDigest", "completionReceiptId"]),
    ("declareConflict", &["subjectActorId", "target", "conflictType", "relationState", "materiality", "temporalState", "sourceClass", "evidenceRefs", "expectedPriorSequence", "policyDigest", "reason", "effectiveAt", "expiresAt"]),
    ("withdrawConflict", &["declarationId", "expectedDeclarationSequence", "expectedDeclarationDigest", "expectedPolicyDigest", "reasonCode", "reason", "effectiveAt", "expiresAt"]),
    ("withdrawActionProposal", &["proposalId", "expectedProposalVersion", "expectedStateVersion", "expectedContentDigest", "reasonCode", "reason"]),
    ("withdrawActionDecision", &["proposalId", "decisionId", "expectedProposalVersion", "expectedProposalStateVersion", "expectedAssignmentVersion", "expectedApprovalDigest", "expectedDecisionReceiptDigest", "reasonCode", "reason"]),
    ("promoteResearchArtifactToEvidence", &["schemaVersion", "caseId", "expectedCaseVersion", "agentRunId", "researchArtifact", "rightsDecision", "evidence", "selectedSegments", "reason"]),
    ("cancelAgentRun", &["schemaVersion", "runId", "expectedVersion", "reasonCode", "reason"]),
    ("reconcileAgentRun", &["schemaVersion", "runId", "expectedVersion", "reconciliationEvidenceId", "reconciliationEvidenceSha256"]),
    ("decideJourneyHandoff", &["schemaVersion", "handoffId", "expectedHandoffVersion", "expectedBindingDigest", "decision", "reasonCode", "reason"]),
];

pub fn validate_control_command(id: &str, payload: &Map<String, Value>) -> bool {
    let Some((_, required)) = CONTROL_REQUIRED_FIELDS
        .iter()
        .find(|(operation, _)| *operation == id)
    else {
        return false;
    };
    required.iter().all(|field| payload.contains_key(*field))
        && payload
            .keys()
            .all(|field| required.contains(&field.as_str()))
}

/// Provider callbacks are private gateway operations, not public API routes.
/// They are exported as typed operation metadata so the notification worker
/// and callback gateway cannot silently invent an operation identifier.
pub const PRIVATE_CONTROL_OPERATIONS: &[OperationSpec] = &[operation!(
    "reconcileAgentRun",
    "control-api-private",
    "POST",
    "/v1/private/agent-runs/{runId}:reconcile",
    "worker-assertion",
    "cases.investigate",
    "SERVICE_ASSERTION",
    "COMMAND",
    200,
    COMMAND_RECEIPT
)];
