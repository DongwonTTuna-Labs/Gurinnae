import { beforeEach, describe, expect, it } from "bun:test";
import { handleMockRequest } from "./mock-api-routes";
import {
  actionJourneyIds,
  type ProviderControlOperationId,
  providerControlOperationIds,
  providerControlPolicies,
  resetAll,
  runtime,
} from "./mock-api-state";

const PROVIDER_ID = "22222222-2222-4222-8222-222222222222";
const ACTOR_ID = "00000000-0000-4000-8000-000000000001";
const EXPIRES_AT = "2026-08-05T12:00:00.000Z";
const paths: Record<ProviderControlOperationId, string> = {
  disableProviderRouting: "/v1/internal/commands/disable-provider-routing",
  testProviderConnection: "/v1/internal/commands/test-provider-connection",
  upgradeProviderModel: "/v1/internal/commands/upgrade-provider-model",
  setModelAutoUpgrade: "/v1/internal/commands/set-model-auto-upgrade",
};

function providerControl(operationId: ProviderControlOperationId) {
  const base = { operationId, providerId: PROVIDER_ID, expectedVersion: 7 };
  switch (operationId) {
    case "disableProviderRouting":
      return { ...base, reason: "장애 격리" };
    case "testProviderConnection":
      return {
        ...base,
        testModel: "relay-model-next",
        reason: "적용 전 연결 검증",
      };
    case "upgradeProviderModel":
      return {
        ...base,
        modelId: "relay-model-next",
        reason: "최신 모델 적용 검토",
        dataPolicy: {
          processingRegion: "KR",
          retentionMode: "ZERO_RETENTION",
          policyVersion: "policy-v1",
        },
      };
    case "setModelAutoUpgrade":
      return {
        ...base,
        enabled: true,
        track: "relay-model-",
        reason: "최신 모델 자동 적용 검토",
      };
  }
}

function createInput(operationId: ProviderControlOperationId) {
  const command = providerControl(operationId);
  const reason = command.reason;
  const rationale = {
    summary: reason,
    evidenceSegmentIds: [],
    unknowns: [],
    alternativesConsidered: [],
    riskNote: reason,
  };
  return {
    actionKind: "PROVIDER_CONTROL",
    origin: { kind: "HUMAN", actorId: ACTOR_ID, screenId: "OPS-005", reason },
    draft: {
      schemaVersion: "action-payload.v1",
      kind: "PROVIDER_CONTROL",
      target: {
        targetType: "CAPABILITY",
        targetId: PROVIDER_ID,
        expectedVersion: 7,
      },
      rationale,
      effect: {
        effectClass: "OPERATIONAL_CONTROL",
        fromState: { aggregate: "CAPABILITY", state: "APPROVED" },
        toState: { aggregate: "CAPABILITY", state: "APPROVED" },
        externalSideEffect: operationId !== "disableProviderRouting",
        reversible: operationId !== "testProviderConnection",
        expectedOutcome: "승인된 공급자 제어 요청 실행",
      },
      providerControl: command,
    },
    rationale,
    expiresAt: EXPIRES_AT,
  };
}

async function command(path: string, payload: unknown) {
  return handleMockRequest(
    new Request(`http://mock.test${path}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload),
    }),
  );
}

async function read(path: string) {
  const request = new Request(`http://mock.test${path}`);
  return handleMockRequest(request);
}

async function json(response: Response): Promise<Record<string, unknown>> {
  const value: unknown = await response.json();
  if (typeof value !== "object" || value === null || Array.isArray(value))
    throw new Error("mock response must be an object");
  return value as Record<string, unknown>;
}

function record(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    throw new Error("expected object");
  return value as Record<string, unknown>;
}

describe("provider-control proposal mock", () => {
  beforeEach(() => resetAll());

  it("omits an absent approval-queue cursor on both routing branches", async () => {
    const baseQueueResponse = await read("/v1/internal/action-proposals");
    expect(baseQueueResponse.status).toBe(200);
    const baseQueue = await json(baseQueueResponse);
    expect(Object.hasOwn(baseQueue, "nextCursor")).toBe(false);

    const createdResponse = await command(
      "/v1/internal/action-proposals",
      createInput("disableProviderRouting"),
    );
    expect(createdResponse.status).toBe(201);

    const combinedQueueResponse = await read("/v1/internal/action-proposals");
    expect(combinedQueueResponse.status).toBe(200);
    const combinedQueue = await json(combinedQueueResponse);
    expect(Object.hasOwn(combinedQueue, "nextCursor")).toBe(false);
  });

  it("keeps all four browser actions on one governed proposal lifecycle", async () => {
    for (const operationId of providerControlOperationIds) {
      resetAll();
      const createdResponse = await command(
        "/v1/internal/action-proposals",
        createInput(operationId),
      );
      expect(createdResponse.status).toBe(201);
      const created = await json(createdResponse);
      const createdProposal = record(created.proposal);
      const proposalId = String(createdProposal.proposalId);
      expect(createdProposal).toMatchObject({
        actionKind: "PROVIDER_CONTROL",
        state: "DRAFT",
        version: 1,
      });

      const draftDetailResponse = await read(
        `/v1/internal/action-proposals/${proposalId}`,
      );
      expect(draftDetailResponse.status).toBe(200);
      const draftQuorum = record((await json(draftDetailResponse)).quorum);
      expect(draftQuorum.requiredSlots).toEqual(["PRIMARY_REVIEWER"]);

      const previewResponse = await command(
        `/v1/internal/action-proposals/${proposalId}:preview`,
        {
          proposalId,
          expectedVersion: 1,
          expectedContentDigest: createdProposal.contentDigest,
        },
      );
      expect(previewResponse.status).toBe(201);
      const preview = record((await json(previewResponse)).preview);
      expect(record(preview.approvalBinding)).toMatchObject({
        actionKind: "PROVIDER_CONTROL",
        actionDetailKind: "PROVIDER_CONTROL",
        operationId,
      });
      expect(record(preview.approvalSubject)).toMatchObject({
        decisionHelp: {
          requiredAssurance: providerControlPolicies[operationId].assurance,
        },
      });

      const reviewResponse = await command(
        `/v1/internal/action-proposals/${proposalId}:submit-review`,
        {
          proposalId,
          expectedVersion: 1,
          expectedContentDigest: createdProposal.contentDigest,
          previewId: preview.previewId,
          previewDigest: preview.previewDigest,
        },
      );
      expect(reviewResponse.status).toBe(200);
      const review = await json(reviewResponse);
      const reviewProposal = record(review.proposal);
      const assignments = review.assignments;
      if (!Array.isArray(assignments) || assignments.length !== 1)
        throw new Error("review assignment missing");
      const assignment = record(assignments[0]);
      expect(reviewProposal).toMatchObject({
        state: "PENDING_QUORUM",
        version: 2,
      });

      const decisionInput = {
        proposalId,
        actionKind: "PROVIDER_CONTROL",
        providerOperationId: operationId,
        assignmentId: assignment.assignmentId,
        expectedProposalVersion: 2,
        expectedAssignmentVersion: 1,
        expectedApprovalDigest: reviewProposal.approvalDigest,
        decision: {
          kind: "APPROVE",
          reasonCode: "PROVIDER_CONTROL_REVIEW",
          reason: "공급자 제어 변경과 버전 결속을 검토했습니다.",
          attestExactPreview: true,
          assurance: providerControlPolicies[operationId].assurance,
          stepUpAuthorizationId: null,
          assertedActionDigest: null,
          stepUpAt: null,
        },
      };
      const prematureDecision = await command(
        `/v1/internal/action-proposals/${proposalId}:decide`,
        decisionInput,
      );
      expect(prematureDecision.status).toBe(409);

      const claimResponse = await command(
        `/v1/internal/action-proposals/${proposalId}:claim-review`,
        {
          proposalId,
          assignmentId: assignment.assignmentId,
          expectedProposalVersion: 2,
          expectedAssignmentVersion: 1,
          expectedApprovalDigest: reviewProposal.approvalDigest,
        },
      );
      expect(claimResponse.status).toBe(200);
      const claimedAssignment = record((await json(claimResponse)).assignment);
      expect(claimedAssignment).toMatchObject({
        assignmentId: assignment.assignmentId,
        version: 2,
        state: "IN_PROGRESS",
      });

      const queueResponse = await read("/v1/internal/action-proposals");
      expect(queueResponse.status).toBe(200);
      const queue = await json(queueResponse);
      if (!Array.isArray(queue.items))
        throw new Error("approval queue items missing");
      const queueProposals = queue.items.map((item) =>
        record(record(item).proposal),
      );
      expect(queueProposals.map((item) => item.actionKind)).toEqual([
        "COMMUNICATION",
        "PROVIDER_CONTROL",
      ]);
      expect(queueProposals.map((item) => item.proposalId)).toEqual([
        actionJourneyIds.proposalId,
        proposalId,
      ]);
      expect(
        (await read(`/v1/internal/action-proposals/${proposalId}`)).status,
      ).toBe(200);
      expect(
        (
          await read(
            `/v1/internal/action-proposals/${actionJourneyIds.proposalId}`,
          )
        ).status,
      ).toBe(200);

      decisionInput.expectedAssignmentVersion = 2;
      const decisionResponse = await command(
        `/v1/internal/action-proposals/${proposalId}:decide`,
        decisionInput,
      );
      expect(decisionResponse.status).toBe(200);
      const decision = await json(decisionResponse);
      const authorization = record(decision.executionAuthorization);
      expect(record(decision.decision).assurance).toBe(
        providerControlPolicies[operationId].assurance,
      );
      expect(authorization).toMatchObject({
        actionKind: "PROVIDER_CONTROL",
        state: "QUEUED",
      });

      const receiptResponse = await read(
        `/v1/internal/action-executions/${authorization.executionId}/receipt`,
      );
      expect(receiptResponse.status).toBe(200);
      const receipt = await json(receiptResponse);
      expect(record(receipt.binding).executorId).toBe(
        "analysis-worker-provider-control",
      );
      expect(receipt).toMatchObject({
        terminal: false,
        reconciliationRequired: false,
      });
      expect(record((receipt.attempts as unknown[])[0])).toMatchObject({
        state: "QUEUED",
        providerAcknowledgementSha256: null,
      });
      expect(record((receipt.receipts as unknown[])[0])).toMatchObject({
        state: "QUEUED",
        providerEvidenceDigest: null,
      });
      expect(runtime.directProviderCommandAttempts).toHaveLength(0);
      expect(
        runtime.providerControlEvents.map((event) => event.operationId),
      ).toEqual([
        "createActionProposal",
        "previewActionDraft",
        "submitActionForReview",
        "claimActionReview",
        "submitActionDecision",
      ]);
    }
  });

  it("rejects every legacy direct provider command instead of faking success", async () => {
    for (const operationId of providerControlOperationIds) {
      const response = await command(
        paths[operationId],
        providerControl(operationId),
      );
      expect(response.status).toBe(409);
      expect((await json(response)).code).toBe("ACTION_PROPOSAL_REQUIRED");
    }
    expect(
      runtime.directProviderCommandAttempts.map((item) => item.operationId),
    ).toEqual(providerControlOperationIds);
  });

  it("fails closed when an inner provider branch contains an unlisted field", async () => {
    const input = createInput("upgradeProviderModel");
    const draft = record(input.draft);
    const provider = record(draft.providerControl);
    provider.unlisted = "forbidden";
    const response = await command("/v1/internal/action-proposals", input);
    expect(response.status).toBe(422);
    expect(runtime.providerControlProposals.size).toBe(0);
  });

  it("fails closed on a zero version or malformed first-activation policy", async () => {
    const zeroVersion = createInput("disableProviderRouting");
    const zeroDraft = record(zeroVersion.draft);
    record(zeroDraft.target).expectedVersion = 0;
    record(zeroDraft.providerControl).expectedVersion = 0;
    expect(
      (await command("/v1/internal/action-proposals", zeroVersion)).status,
    ).toBe(422);

    const invalidPolicy = createInput("upgradeProviderModel");
    const invalidDraft = record(invalidPolicy.draft);
    const policy = record(record(invalidDraft.providerControl).dataPolicy);
    policy.processingRegion = "ap-northeast-2";
    expect(
      (await command("/v1/internal/action-proposals", invalidPolicy)).status,
    ).toBe(422);
    expect(runtime.providerControlProposals.size).toBe(0);
  });
});
