import {
  actionJourneyDigests,
  actionJourneyIds,
  runtime,
} from "./mock-api-state";

export function actionProposalSummary() {
  const now = new Date().toISOString();
  return {
    proposalId: actionJourneyIds.proposalId,
    version: 1,
    actionKind: "COMMUNICATION",
    state: runtime.actionJourney.proposalState,
    contentDigest: actionJourneyDigests.content,
    approvalDigest: actionJourneyDigests.approval,
    target: {
      targetType: "CASE",
      targetId: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      expectedVersion: 1,
    },
    creator: {
      actorType: "USER",
      actorId: "00000000-0000-4000-8000-000000000001",
      displayName: "E2E 제안자",
    },
    lastEditor: {
      actorType: "USER",
      actorId: "00000000-0000-4000-8000-000000000001",
      displayName: "E2E 제안자",
    },
    createdAt: now,
    updatedAt: now,
    expiresAt: new Date(Date.now() + 900_000).toISOString(),
  };
}

export function actionAssignment() {
  return {
    assignmentId: actionJourneyIds.assignmentId,
    version: 1,
    assignmentGeneration: 1,
    slotKind: "PRIMARY_REVIEWER",
    requiredCapability: "actions.review",
    reviewer: null,
    state: "PENDING",
    dueAt: new Date(Date.now() + 900_000).toISOString(),
    approvalDigest: actionJourneyDigests.approval,
    handoffId:
      runtime.actionJourney.proposalState === "APPROVED"
        ? actionJourneyIds.handoffId
        : null,
    handoffVersion:
      runtime.actionJourney.proposalState === "APPROVED"
        ? runtime.actionJourney.handoffVersion
        : null,
    bindingDigest:
      runtime.actionJourney.proposalState === "APPROVED"
        ? actionJourneyDigests.binding
        : null,
  };
}

export function actionQueueResponse() {
  return {
    items: [
      {
        proposal: actionProposalSummary(),
        assignment: actionAssignment(),
        quorum: {
          planDigest: actionJourneyDigests.binding,
          requiredSlots: ["PRIMARY_REVIEWER"],
          satisfiedSlots:
            runtime.actionJourney.proposalState === "APPROVED"
              ? ["PRIMARY_REVIEWER"]
              : [],
          blockingSlots:
            runtime.actionJourney.proposalState === "APPROVED"
              ? []
              : ["PRIMARY_REVIEWER"],
          conflictSnapshotDigest: actionJourneyDigests.content,
          complete: runtime.actionJourney.proposalState === "APPROVED",
        },
        dueAt: new Date(Date.now() + 900_000).toISOString(),
        riskClass: "MEDIUM",
        href: {
          href: `/internal/my-work?proposalId=${actionJourneyIds.proposalId}`,
        },
      },
    ],
    appliedFilters: {
      actionKind: ["COMMUNICATION"],
      proposalState: [runtime.actionJourney.proposalState],
      assignmentState: ["PENDING"],
      dueBefore: new Date(Date.now() + 900_000).toISOString(),
      sort: "dueAt",
    },
    asOf: new Date().toISOString(),
    nextCursor: {},
    totalApproximate: 1,
  };
}

export function actionProposalDetail() {
  const proposal = actionProposalSummary();
  const assignment = actionAssignment();
  const handoff =
    runtime.actionJourney.proposalState === "APPROVED"
      ? {
          handoffId: actionJourneyIds.handoffId,
          handoffVersion: runtime.actionJourney.handoffVersion,
          bindingDigest: actionJourneyDigests.binding,
        }
      : {};
  return {
    proposal,
    origin: { journeyId: "J-11", node: "INT-002" },
    payload: {
      target: { targetId: proposal.target.targetId, scope: "case" },
      communication: {
        provider: "smtp",
        endpoint: "destination@example.test",
        body: "검토가 완료된 외부 전달 내용입니다.",
        consent: "수신자 동의와 전송 범위를 확인했습니다.",
        attachments: [],
      },
    },
    rationale: {
      summary: "검토 완료 사실을 담당자에게 전달합니다.",
      evidenceSegmentIds: ["evidence-001"],
      unknowns: [],
      alternativesConsidered: ["전달하지 않음"],
      riskNote: "수신자와 본문을 승인 지문에 결속합니다.",
    },
    latestPreview: {
      previewId: "ffffffff-ffff-4fff-8fff-ffffffffffff",
      previewDigest: actionJourneyDigests.content,
    },
    assignmentHistory: {
      items: [assignment],
      nextCursor: null,
      asOf: new Date().toISOString(),
    },
    decisionHistory: {
      items:
        runtime.actionJourney.decision === null
          ? []
          : [
              {
                decisionId: "99999999-9999-4999-8999-999999999999",
                decision: runtime.actionJourney.decision,
                receiptDigest: actionJourneyDigests.receipt,
              },
            ],
      nextCursor: null,
      asOf: new Date().toISOString(),
    },
    quorum: {
      planDigest: actionJourneyDigests.binding,
      requiredSlots: ["PRIMARY_REVIEWER"],
      satisfiedSlots:
        runtime.actionJourney.proposalState === "APPROVED"
          ? ["PRIMARY_REVIEWER"]
          : [],
      blockingSlots:
        runtime.actionJourney.proposalState === "APPROVED"
          ? []
          : ["PRIMARY_REVIEWER"],
      conflictSnapshotDigest: actionJourneyDigests.content,
      complete: runtime.actionJourney.proposalState === "APPROVED",
    },
    executionAuthorization: runtime.actionJourney.executionId,
    asOf: new Date().toISOString(),
    links: [],
    ...handoff,
  };
}

export function actionExecutionReceipt() {
  const executionId =
    runtime.actionJourney.executionId ?? actionJourneyIds.executionId;
  return {
    authorization: {
      executionId,
      state: "AUTHORIZED",
      approvalDigest: actionJourneyDigests.approval,
      expiresAt: new Date(Date.now() + 900_000).toISOString(),
    },
    binding: {
      executionId,
      generation: 1,
      approvalDigest: actionJourneyDigests.approval,
      targetRequestSha256: actionJourneyDigests.content,
      providerIdempotencyKeySha256: actionJourneyDigests.binding,
      destination: "destination@example.test",
    },
    attempts: [
      {
        attemptId: "12121212-1212-4121-8121-121212121212",
        ordinal: 1,
        state: "SUCCEEDED",
        providerAcknowledgementSha256: actionJourneyDigests.receipt,
      },
    ],
    receipts: [
      {
        receiptId: "13131313-1313-4131-8131-131313131313",
        executionId,
        sequence: 1,
        state: "DELIVERED",
        receiptDigest: actionJourneyDigests.receipt,
        destination: "destination@example.test",
      },
    ],
    terminal: true,
    reconciliationRequired: false,
    asOf: new Date().toISOString(),
    links: ["/internal/my-work"],
  };
}
