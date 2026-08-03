import { indexOperations, type OpenApiDocument } from "@gurine/config";
import controlOpenApi from "../../../../../specs/generated/control-api.openapi.json";
import identityOpenApi from "../../../../../specs/generated/identity-provider.openapi.json";

export const operations = indexOperations([
  controlOpenApi as OpenApiDocument,
  identityOpenApi as OpenApiDocument,
]);

/** Owner-addendum control operations intentionally kept visible to the BFF. */
export const ADDENDUM_CONTROL_OPERATION_IDS = Object.freeze([
  "listActionApprovalQueue",
  "createActionProposal",
  "getActionProposal",
  "updateActionDraft",
  "previewActionDraft",
  "submitActionForReview",
  "claimActionReview",
  "submitActionDecision",
  "getActionExecutionReceipt",
  "cancelActionExecution",
  "retryActionExecution",
  "releaseLegalHold",
  "getCommunicationDeliveryReceipt",
  "reconcileCommunicationDelivery",
  "cancelCommunicationDelivery",
  "getIncident",
  "triageIncident",
  "containIncident",
  "startIncidentRecovery",
  "resolveIncident",
  "closeIncidentPostmortem",
  "listResponseAppeals",
  "getResponseAppealWorkspace",
  "transitionResponseAppeal",
  "decideResponseExtension",
  "listRetentionRequests",
  "getRetentionRequest",
  "transitionRetentionRequest",
  "listRecordClassSchedules",
  "declareConflict",
  "withdrawConflict",
  "withdrawActionProposal",
  "withdrawActionDecision",
  "promoteResearchArtifactToEvidence",
  "cancelAgentRun",
  "decideJourneyHandoff",
] as const);
