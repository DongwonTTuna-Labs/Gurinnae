import { randomUUID } from "node:crypto";
import {
  actionDecisionSummary,
  actionProposalSummary,
  actionQuorum,
  executionAuthorizationSummary,
} from "./mock-api-action-reads";
import {
  actionJourneyDigests,
  actionJourneyIds,
  body,
  problem,
  runtime,
  sha256,
} from "./mock-api-state";

function commandReceipt(
  operationId: string,
  aggregateId: string,
  version: number,
) {
  return {
    operationId,
    requestId: randomUUID(),
    status: "COMPLETED",
    aggregateId,
    aggregateVersion: version,
    auditEventId: randomUUID(),
    acceptedAt: new Date().toISOString(),
    receiptDigest: actionJourneyDigests.receipt,
    emittedEventIds: [randomUUID()],
    idempotencyReplay: false,
    links: [],
  };
}

export async function handleCommandRoutes(
  request: Request,
  url: URL,
): Promise<Response | undefined> {
  if (
    url.pathname ===
      `/v1/internal/action-proposals/${actionJourneyIds.proposalId}:decide` &&
    request.method === "POST"
  ) {
    const input = await body(request);
    const decision =
      typeof input.decision === "object" && input.decision !== null
        ? (input.decision as Record<string, unknown>)
        : {};
    const kind = typeof decision.kind === "string" ? decision.kind : "";
    if (
      input.proposalId !== actionJourneyIds.proposalId ||
      input.expectedProposalVersion !== 1 ||
      input.expectedAssignmentVersion !== 1 ||
      input.expectedApprovalDigest !== actionJourneyDigests.approval ||
      input.assignmentId !== actionJourneyIds.assignmentId
    ) {
      return problem(409, "ACTION_PROPOSAL_STALE");
    }
    if (!runtime.actionJourney.proposalState.startsWith("PENDING"))
      return problem(422, "ACTION_DECISION_CLOSED");
    if (!kind) return problem(422, "ACTION_KIND_MISMATCH");
    const before = runtime.actionJourney.proposalState;
    const approved = kind === "APPROVE";
    runtime.actionJourney.decision = approved ? "APPROVE" : "REJECT";
    runtime.actionJourney.proposalState = approved ? "APPROVED" : "REJECTED";
    runtime.actionJourney.executionId = approved
      ? actionJourneyIds.executionId
      : null;
    runtime.actionJourney.events.push({
      operationId: "submitActionDecision",
      before,
      after: runtime.actionJourney.proposalState,
      proposalId: actionJourneyIds.proposalId,
      digest: actionJourneyDigests.approval,
    });
    const executionAuthorization = approved
      ? executionAuthorizationSummary(actionJourneyIds.executionId)
      : null;
    return Response.json({
      command: commandReceipt(
        "submitActionDecision",
        actionJourneyIds.proposalId,
        2,
      ),
      proposal: actionProposalSummary(),
      decision: actionDecisionSummary(),
      quorum: actionQuorum(),
      executionAuthorization,
    });
  }

  if (
    url.pathname ===
      `/v1/internal/journey-handoffs/${actionJourneyIds.handoffId}:decide` &&
    request.method === "POST"
  ) {
    const input = await body(request);
    const decision = input.decision;
    if (
      input.handoffId !== actionJourneyIds.handoffId ||
      input.expectedHandoffVersion !== runtime.actionJourney.handoffVersion ||
      input.expectedBindingDigest !== actionJourneyDigests.binding
    ) {
      return problem(409, "VERSION_CONFLICT");
    }
    if (runtime.actionJourney.proposalState !== "APPROVED")
      return problem(422, "HANDOFF_STATE_INVALID");
    const acknowledge = decision === "ACKNOWLEDGE";
    const before = runtime.actionJourney.handoffState;
    runtime.actionJourney.handoffState = acknowledge
      ? "ACKNOWLEDGED"
      : "DECLINED";
    runtime.actionJourney.handoffVersion += 1;
    runtime.actionJourney.events.push({
      operationId: "decideJourneyHandoff",
      before,
      after: runtime.actionJourney.handoffState,
      proposalId: actionJourneyIds.proposalId,
      digest: actionJourneyDigests.binding,
    });
    const terminalDecision = acknowledge ? "ACKNOWLEDGE" : "DECLINE";
    const resultingJourneyState = acknowledge ? "ACTIVE" : "BLOCKED";
    const now = new Date().toISOString();
    const dueAt = new Date(Date.now() + 900_000).toISOString();
    const journeyInstanceId = "16161616-1616-4161-8161-161616161616";
    return Response.json({
      schemaVersion: "journey-handoff-decision-receipt.v1",
      command: commandReceipt(
        "decideJourneyHandoff",
        actionJourneyIds.handoffId,
        runtime.actionJourney.handoffVersion,
      ),
      decisionReceipt: {
        receiptId: randomUUID(),
        receiptDigest: actionJourneyDigests.receipt,
        journeyInstanceId,
        journeyInstanceVersion: runtime.actionJourney.handoffVersion,
        handoffId: actionJourneyIds.handoffId,
        handoffVersion: runtime.actionJourney.handoffVersion,
        handoffKind: "HS-09-ACTION_EXECUTION_CLAIM",
        generation: 1,
        decision: terminalDecision,
        resultingHandoffState: runtime.actionJourney.handoffState,
        resultingJourneyState,
        currentOwnerBindingDigest: actionJourneyDigests.binding,
        nextOwnerBindingDigest: null,
        auditEventId: randomUUID(),
        outboxEventId: randomUUID(),
      },
      replacement: null,
      finalParent: {
        journeyInstanceId,
        version: runtime.actionJourney.handoffVersion,
        state: resultingJourneyState,
        currentOwnerBindingDigest: actionJourneyDigests.binding,
        nextOwnerBindingDigest: null,
        activeHandoffId: null,
        activeHandoffGeneration: null,
        activeHandoffState: null,
        escalationState: "RESOLVED",
        dueAt,
        headReceiptId: randomUUID(),
        headReceiptDigest: actionJourneyDigests.receipt,
      },
      effectDigest: actionJourneyDigests.receipt,
      decidedAt: now,
    });
  }

  if (
    url.pathname === "/v1/internal/commands/publish-case" &&
    request.method === "POST"
  ) {
    const bytes = await request.text();
    const idempotencyKey = request.headers.get("idempotency-key") ?? "";
    const actorAssertion =
      request.headers.get("x-gurine-actor-assertion") ?? "";
    if (!idempotencyKey || !actorAssertion)
      return problem(401, "ACTOR_ASSERTION_REQUIRED");
    runtime.commandAttempts.push({
      bodySha256: sha256(bytes),
      idempotencyKeySha256: sha256(idempotencyKey),
      actorAssertionSha256: sha256(actorAssertion),
    });
    if (runtime.commandAttempts.length < 3)
      return problem(503, "UPSTREAM_TEMPORARY_FAILURE");
    return Response.json(
      {
        operationId: "publishCase",
        requestId: randomUUID(),
        status: "completed",
        aggregateId: "00000000-0000-4000-8000-000000000010",
        aggregateVersion: 2,
        auditEventId: randomUUID(),
        acceptedAt: new Date().toISOString(),
        links: [],
      },
      { status: 201 },
    );
  }
  return undefined;
}
