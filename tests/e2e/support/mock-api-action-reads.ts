import {
  actionJourneyDigests,
  actionJourneyIds,
  runtime,
} from "./mock-api-state";

const ACTOR_ID = "00000000-0000-4000-8000-000000000001";
const CASE_ID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const DECISION_ID = "99999999-9999-4999-8999-999999999999";
const SENDER_CONFIG_ID = "10101010-1010-4010-8010-101010101010";
const TEMPLATE_ID = "11111111-1111-4111-8111-111111111111";
const RECIPIENT_SUBJECT_ID = "14141414-1414-4141-8141-141414141414";
const RECIPIENT_ENDPOINT_ID = "15151515-1515-4151-8151-151515151515";

const futureTimestamp = () => new Date(Date.now() + 900_000).toISOString();

function actorSummary() {
  return {
    actorType: "HUMAN",
    actorId: ACTOR_ID,
    displayName: "E2E 검토자",
  };
}

function actionRationale() {
  return {
    summary: "검토 완료 사실을 담당자에게 전달합니다.",
    evidenceSegmentIds: ["evidence-001"],
    unknowns: [],
    alternativesConsidered: ["전달하지 않음"],
    riskNote: "수신자와 본문을 승인 지문에 결속합니다.",
  };
}

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
      targetId: CASE_ID,
      expectedVersion: 1,
    },
    creator: actorSummary(),
    lastEditor: actorSummary(),
    createdAt: now,
    updatedAt: now,
    expiresAt: futureTimestamp(),
  };
}

export function actionAssignment() {
  return {
    assignmentId: actionJourneyIds.assignmentId,
    version: 1,
    assignmentGeneration: 1,
    slotKind: "PRIMARY_REVIEWER",
    requiredCapability: "actions.review",
    reviewer: actorSummary(),
    state: runtime.actionJourney.decision === null ? "ASSIGNED" : "COMPLETED",
    dueAt: futureTimestamp(),
    approvalDigest: actionJourneyDigests.approval,
  };
}

export function actionQuorum() {
  const complete = runtime.actionJourney.proposalState === "APPROVED";
  return {
    planDigest: actionJourneyDigests.binding,
    requiredSlots: ["PRIMARY_REVIEWER"],
    satisfiedSlots: complete ? ["PRIMARY_REVIEWER"] : [],
    blockingSlots: complete ? [] : ["PRIMARY_REVIEWER"],
    conflictSnapshotDigest: actionJourneyDigests.content,
    complete,
  };
}

export function executionAuthorizationSummary(executionId: string) {
  return {
    executionId,
    generation: 1,
    stateVersion: 1,
    actionKind: "COMMUNICATION",
    state: "SUCCEEDED",
    executionDigest: actionJourneyDigests.binding,
    cancellationGeneration: 0,
    expiresAt: futureTimestamp(),
  };
}

export function actionDecisionSummary() {
  return {
    recordKind: "DECISION",
    decisionId: DECISION_ID,
    assignmentId: actionJourneyIds.assignmentId,
    assignmentGeneration: 1,
    decisionKind: runtime.actionJourney.decision ?? "REJECT",
    actor: actorSummary(),
    slotKind: "PRIMARY_REVIEWER",
    capability: "actions.review",
    assurance: "STEP_UP",
    reasonCode: "E2E_REVIEW",
    reason: "승인 지문과 외부 전달 범위를 검토했습니다.",
    approvalDigest: actionJourneyDigests.approval,
    receiptDigest: actionJourneyDigests.receipt,
    decidedAt: new Date().toISOString(),
  };
}

export function actionQueueResponse() {
  const assignment = actionAssignment();
  return {
    items: [
      {
        proposal: actionProposalSummary(),
        assignment,
        quorum: actionQuorum(),
        dueAt: assignment.dueAt,
        riskClass: "MEDIUM",
        href: `/internal/my-work?proposalId=${actionJourneyIds.proposalId}`,
      },
    ],
    appliedFilters: {
      actionKind: ["COMMUNICATION"],
      proposalState: [runtime.actionJourney.proposalState],
      assignmentState: [assignment.state],
      dueBefore: futureTimestamp(),
      sort: "DUE_ASC",
    },
    asOf: new Date().toISOString(),
    nextCursor: null,
    totalApproximate: 1,
    operationId: "listActionApprovalQueue",
    links: [],
  };
}

export function actionProposalDetail() {
  const proposal = actionProposalSummary();
  const assignment = actionAssignment();
  const now = new Date().toISOString();
  const rationale = actionRationale();
  const executionId = runtime.actionJourney.executionId;
  return {
    proposal,
    origin: {
      kind: "HUMAN",
      actorId: ACTOR_ID,
      screenId: "INT-002",
      reason: "외부 전달 전 사람 검토가 필요합니다.",
    },
    payload: {
      schemaVersion: "action-payload.v1",
      kind: "COMMUNICATION",
      target: proposal.target,
      rationale,
      effect: {
        effectClass: "EXTERNAL_COMMUNICATION",
        fromState: {
          aggregate: "COMMUNICATION",
          state: "AWAITING_APPROVAL",
        },
        toState: { aggregate: "COMMUNICATION", state: "DELIVERED" },
        externalSideEffect: true,
        reversible: false,
        expectedOutcome: "승인된 본문이 지정 수신자에게 전달됩니다.",
      },
      caseId: CASE_ID,
      expectedCaseVersion: 1,
      purpose: "DISCRETIONARY_EXTERNAL",
      provider: "SMTP_EMAIL",
      senderConfigId: SENDER_CONFIG_ID,
      templateId: TEMPLATE_ID,
      templateRevision: 1,
      locale: "ko-KR",
      recipients: [
        {
          ordinal: 1,
          subjectId: RECIPIENT_SUBJECT_ID,
          endpointId: RECIPIENT_ENDPOINT_ID,
          endpointVersion: 1,
          role: "PRIMARY",
          destinationIdentitySha256: actionJourneyDigests.content,
          consentSnapshotDigest: actionJourneyDigests.approval,
          suppressionSnapshotDigest: actionJourneyDigests.binding,
        },
      ],
      subject: "외부 전달 검토 완료",
      bodyPlainText: "검토가 완료된 외부 전달 내용입니다.",
      attachmentIds: [],
      authorizationPurpose: "검토 완료 결과 전달",
      maximumCost: { amount: 0, currency: "KRW" },
      notBefore: now,
      expiresAt: futureTimestamp(),
    },
    rationale,
    latestPreview: null,
    assignmentHistory: {
      items: [assignment],
      order: "slot-ordinal-asc-generation-asc-assignment-id-asc",
      asOf: now,
      pageDigest: actionJourneyDigests.binding,
      nextCursor: null,
      complete: true,
    },
    decisionHistory: {
      items:
        runtime.actionJourney.decision === null
          ? []
          : [actionDecisionSummary()],
      order: "decided-at-asc-decision-id-asc",
      asOf: now,
      pageDigest: actionJourneyDigests.receipt,
      nextCursor: null,
      complete: true,
    },
    quorum: actionQuorum(),
    executionAuthorization:
      executionId === null ? null : executionAuthorizationSummary(executionId),
    asOf: now,
    links: [],
    operationId: "getActionProposal",
  };
}

export function actionExecutionReceipt() {
  const executionId =
    runtime.actionJourney.executionId ?? actionJourneyIds.executionId;
  const now = new Date().toISOString();
  return {
    authorization: executionAuthorizationSummary(executionId),
    binding: {
      schemaVersion: "execution-binding.v1",
      executionId,
      generation: 1,
      approvalDigest: actionJourneyDigests.approval,
      countedDecisionReceiptDigests: [actionJourneyDigests.receipt],
      executorId: "mock-communication-executor",
      targetRequestSha256: actionJourneyDigests.content,
      providerIdempotencyKeySha256: actionJourneyDigests.binding,
      budgetReservationDigest: actionJourneyDigests.binding,
      cancellationGeneration: 0,
      expiresAt: futureTimestamp(),
    },
    attempts: [
      {
        attemptId: "12121212-1212-4121-8121-121212121212",
        ordinal: 1,
        generation: 1,
        fencingToken: 1,
        state: "SUCCEEDED",
        providerIdempotencyKeySha256: actionJourneyDigests.binding,
        providerAcknowledgementSha256: actionJourneyDigests.receipt,
        startedAt: now,
        finishedAt: now,
        actualCost: { amount: 0, currency: "KRW" },
        failureCode: null,
      },
    ],
    receipts: [
      {
        receiptId: "13131313-1313-4131-8131-131313131313",
        sequence: 1,
        executionId,
        generation: 1,
        stateVersion: 1,
        state: "SUCCEEDED",
        providerEvidenceDigest: actionJourneyDigests.receipt,
        reconciliationEvidenceDigest: null,
        recordedAt: now,
        receiptDigest: actionJourneyDigests.receipt,
      },
    ],
    terminal: true,
    reconciliationRequired: false,
    asOf: now,
    links: [],
    operationId: "getActionExecutionReceipt",
  };
}
