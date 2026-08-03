import { randomUUID } from "node:crypto";
import { buildProviderPreview } from "./mock-api-provider-proposal-preview";
import {
  providerAssignment,
  providerExecutionAuthorization,
  providerProposalSummary,
  providerQuorum,
} from "./mock-api-provider-proposal-reads";
import {
  createProviderProposal,
  observeProviderProposal,
  parseProviderProposalCreate,
} from "./mock-api-provider-proposal-state";
import {
  addendumProblem,
  body,
  canonicalJsonSha256,
  type ProviderControlOperationId,
  type ProviderControlProposal,
  providerControlPolicies,
  runtime,
  sha256,
} from "./mock-api-state";

const directCommandPaths = new Map<string, ProviderControlOperationId>([
  ["/v1/internal/commands/disable-provider-routing", "disableProviderRouting"],
  ["/v1/internal/commands/test-provider-connection", "testProviderConnection"],
  ["/v1/internal/commands/upgrade-provider-model", "upgradeProviderModel"],
  ["/v1/internal/commands/set-model-auto-upgrade", "setModelAutoUpgrade"],
]);

function commandReceipt(
  operationId: string,
  proposal: ProviderControlProposal,
) {
  return {
    operationId,
    requestId: randomUUID(),
    status: "COMPLETED",
    aggregateId: proposal.proposalId,
    aggregateVersion: proposal.version,
    auditEventId: randomUUID(),
    acceptedAt: new Date().toISOString(),
    receiptDigest: canonicalJsonSha256({
      operationId,
      proposalId: proposal.proposalId,
      version: proposal.version,
      state: proposal.state,
    }),
    emittedEventIds: [randomUUID()],
    idempotencyReplay: false,
    links: [],
  };
}

function proposalFromPath(pathname: string, suffix: string) {
  if (!pathname.endsWith(suffix)) return undefined;
  const proposalId = pathname.slice(
    "/v1/internal/action-proposals/".length,
    -suffix.length,
  );
  return runtime.providerControlProposals.get(proposalId);
}

function isExactInput(input: Record<string, unknown>, keys: readonly string[]) {
  return (
    keys.every((key) => Object.hasOwn(input, key)) &&
    Object.keys(input).every((key) => keys.includes(key))
  );
}

function current(
  input: Record<string, unknown>,
  proposal: ProviderControlProposal,
) {
  return (
    input.proposalId === proposal.proposalId &&
    input.expectedVersion === proposal.version &&
    input.expectedContentDigest === proposal.contentDigest
  );
}

async function createProposal(request: Request) {
  const input = await body(request);
  const parsed = parseProviderProposalCreate(input);
  if (!parsed.ok)
    return addendumProblem(422, "INVALID_PARAMETER", parsed.message);
  const proposal = createProviderProposal(parsed);
  return Response.json(
    {
      command: commandReceipt("createActionProposal", proposal),
      proposal: providerProposalSummary(proposal),
    },
    { status: 201 },
  );
}

async function previewProposal(
  request: Request,
  proposal: ProviderControlProposal,
) {
  const input = await body(request);
  if (
    proposal.state !== "DRAFT" ||
    !isExactInput(input, [
      "proposalId",
      "expectedVersion",
      "expectedContentDigest",
    ]) ||
    !current(input, proposal)
  )
    return addendumProblem(409, "ACTION_PROPOSAL_STALE");
  const previewId = randomUUID();
  const preview = buildProviderPreview(proposal, previewId);
  proposal.previewId = previewId;
  proposal.previewVersion = proposal.version;
  proposal.previewDigest = preview.previewDigest;
  proposal.approvalDigest = preview.approvalDigest;
  proposal.updatedAt = new Date().toISOString();
  observeProviderProposal("previewActionDraft", proposal);
  return Response.json(
    {
      command: commandReceipt("previewActionDraft", proposal),
      preview,
    },
    { status: 201 },
  );
}

async function submitForReview(
  request: Request,
  proposal: ProviderControlProposal,
) {
  const input = await body(request);
  if (
    proposal.state !== "DRAFT" ||
    !proposal.previewId ||
    !proposal.previewDigest ||
    !isExactInput(input, [
      "proposalId",
      "expectedVersion",
      "expectedContentDigest",
      "previewId",
      "previewDigest",
    ]) ||
    !current(input, proposal) ||
    input.previewId !== proposal.previewId ||
    input.previewDigest !== proposal.previewDigest
  )
    return addendumProblem(409, "ACTION_PREVIEW_STALE");
  proposal.version += 1;
  proposal.state = "PENDING_QUORUM";
  proposal.assignmentId = randomUUID();
  proposal.assignmentVersion = 1;
  proposal.assignmentState = "ASSIGNED";
  proposal.updatedAt = new Date().toISOString();
  observeProviderProposal("submitActionForReview", proposal);
  const assignment = providerAssignment(proposal);
  return Response.json({
    command: commandReceipt("submitActionForReview", proposal),
    proposal: providerProposalSummary(proposal),
    assignments: assignment ? [assignment] : [],
    quorum: providerQuorum(proposal),
  });
}

async function claimReview(
  request: Request,
  proposal: ProviderControlProposal,
) {
  const input = await body(request);
  if (
    proposal.state !== "PENDING_QUORUM" ||
    !proposal.assignmentId ||
    proposal.assignmentVersion === null ||
    proposal.assignmentState !== "ASSIGNED" ||
    !isExactInput(input, [
      "proposalId",
      "assignmentId",
      "expectedProposalVersion",
      "expectedAssignmentVersion",
      "expectedApprovalDigest",
    ]) ||
    input.proposalId !== proposal.proposalId ||
    input.assignmentId !== proposal.assignmentId ||
    input.expectedProposalVersion !== proposal.version ||
    input.expectedAssignmentVersion !== proposal.assignmentVersion ||
    input.expectedApprovalDigest !== proposal.approvalDigest
  )
    return addendumProblem(409, "ACTION_PROPOSAL_STALE");
  proposal.assignmentVersion += 1;
  proposal.assignmentState = "IN_PROGRESS";
  proposal.updatedAt = new Date().toISOString();
  observeProviderProposal("claimActionReview", proposal);
  const assignment = providerAssignment(proposal);
  if (!assignment)
    return addendumProblem(500, "ACTION_ASSIGNMENT_STATE_INVALID");
  return Response.json({
    command: commandReceipt("claimActionReview", proposal),
    proposalId: proposal.proposalId,
    proposalVersion: proposal.version,
    assignment,
  });
}

function decisionKind(
  input: Record<string, unknown>,
  proposal: ProviderControlProposal,
) {
  const decision = input.decision;
  if (typeof decision !== "object" || decision === null) return undefined;
  const value = decision as Record<string, unknown>;
  if (value.kind === "REJECT")
    return isExactInput(value, ["kind", "reasonCode", "reason"]) &&
      typeof value.reasonCode === "string" &&
      typeof value.reason === "string"
      ? "REJECT"
      : undefined;
  const expectedAssurance =
    providerControlPolicies[proposal.payload.providerControl.operationId]
      .assurance;
  return value.kind === "APPROVE" &&
    isExactInput(value, [
      "kind",
      "reasonCode",
      "reason",
      "attestExactPreview",
      "assurance",
      "stepUpAuthorizationId",
      "assertedActionDigest",
      "stepUpAt",
    ]) &&
    typeof value.reasonCode === "string" &&
    typeof value.reason === "string" &&
    value.attestExactPreview === true &&
    value.assurance === expectedAssurance
    ? "APPROVE"
    : undefined;
}

async function decideProposal(
  request: Request,
  proposal: ProviderControlProposal,
) {
  const input = await body(request);
  const kind = decisionKind(input, proposal);
  const providerOperationId = proposal.payload.providerControl.operationId;
  if (
    proposal.state !== "PENDING_QUORUM" ||
    !proposal.assignmentId ||
    proposal.assignmentVersion === null ||
    proposal.assignmentState !== "IN_PROGRESS" ||
    !isExactInput(input, [
      "proposalId",
      "actionKind",
      "providerOperationId",
      "assignmentId",
      "expectedProposalVersion",
      "expectedAssignmentVersion",
      "expectedApprovalDigest",
      "decision",
    ]) ||
    input.proposalId !== proposal.proposalId ||
    input.actionKind !== "PROVIDER_CONTROL" ||
    input.providerOperationId !== providerOperationId ||
    input.assignmentId !== proposal.assignmentId ||
    input.expectedProposalVersion !== proposal.version ||
    input.expectedAssignmentVersion !== proposal.assignmentVersion ||
    input.expectedApprovalDigest !== proposal.approvalDigest ||
    !kind
  )
    return addendumProblem(409, "ACTION_PROPOSAL_STALE");
  proposal.version += 1;
  proposal.decisionId = randomUUID();
  proposal.decision = kind;
  proposal.state = kind === "APPROVE" ? "APPROVED" : "REJECTED";
  proposal.assignmentVersion += 1;
  proposal.assignmentState = "COMPLETED";
  proposal.updatedAt = new Date().toISOString();
  if (kind === "APPROVE") {
    proposal.executionId = randomUUID();
    proposal.executionJobId = randomUUID();
    proposal.executionReceiptId = randomUUID();
  }
  observeProviderProposal("submitActionDecision", proposal);
  const decisionReceiptDigest = canonicalJsonSha256({
    proposalId: proposal.proposalId,
    decisionId: proposal.decisionId,
    decision: kind,
    approvalDigest: proposal.approvalDigest,
  });
  return Response.json({
    command: commandReceipt("submitActionDecision", proposal),
    proposal: providerProposalSummary(proposal),
    decision: {
      recordKind: "DECISION",
      decisionId: proposal.decisionId,
      assignmentId: proposal.assignmentId,
      assignmentGeneration: 1,
      decisionKind: kind,
      actor: {
        actorType: "HUMAN",
        actorId: "00000000-0000-4000-8000-000000000001",
        displayName: "E2E 검토자",
      },
      slotKind: "PRIMARY_REVIEWER",
      capability: "actions.review",
      assurance: providerControlPolicies[providerOperationId].assurance,
      reasonCode: "PROVIDER_CONTROL_REVIEW",
      reason: "공급자 제어 변경과 버전 결속을 검토했습니다.",
      approvalDigest: proposal.approvalDigest,
      receiptDigest: decisionReceiptDigest,
      decidedAt: proposal.updatedAt,
    },
    quorum: providerQuorum(proposal),
    executionAuthorization: providerExecutionAuthorization(proposal),
  });
}

export async function handleProviderProposalCommands(
  request: Request,
  url: URL,
): Promise<Response | undefined> {
  const directOperation = directCommandPaths.get(url.pathname);
  if (request.method === "POST" && directOperation) {
    const bytes = await request.text();
    runtime.directProviderCommandAttempts.push({
      operationId: directOperation,
      bodySha256: sha256(bytes),
    });
    return addendumProblem(409, "ACTION_PROPOSAL_REQUIRED");
  }
  if (
    request.method === "POST" &&
    url.pathname === "/v1/internal/action-proposals"
  )
    return createProposal(request);
  if (request.method !== "POST") return undefined;
  const preview = proposalFromPath(url.pathname, ":preview");
  if (preview) return previewProposal(request, preview);
  const review = proposalFromPath(url.pathname, ":submit-review");
  if (review) return submitForReview(request, review);
  const claimed = proposalFromPath(url.pathname, ":claim-review");
  if (claimed) return claimReview(request, claimed);
  const decision = proposalFromPath(url.pathname, ":decide");
  if (decision) return decideProposal(request, decision);
  return undefined;
}
