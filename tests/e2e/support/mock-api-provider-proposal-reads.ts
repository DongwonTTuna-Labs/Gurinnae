import {
  canonicalJsonSha256,
  type ProviderControlProposal,
  providerControlPolicies,
} from "./mock-api-state";

const ACTOR_ID = "00000000-0000-4000-8000-000000000001";

const now = () => new Date().toISOString();

function actorSummary() {
  return {
    actorType: "HUMAN",
    actorId: ACTOR_ID,
    displayName: "E2E 검토자",
  };
}

export function providerProposalSummary(proposal: ProviderControlProposal) {
  return {
    proposalId: proposal.proposalId,
    version: proposal.version,
    actionKind: "PROVIDER_CONTROL",
    state: proposal.state,
    contentDigest: proposal.contentDigest,
    approvalDigest: proposal.approvalDigest,
    target: proposal.target,
    creator: actorSummary(),
    lastEditor: actorSummary(),
    createdAt: proposal.createdAt,
    updatedAt: proposal.updatedAt,
    expiresAt: proposal.expiresAt,
  };
}

export function providerAssignment(proposal: ProviderControlProposal) {
  if (
    !proposal.assignmentId ||
    proposal.assignmentVersion === null ||
    proposal.assignmentState === null
  )
    return null;
  return {
    assignmentId: proposal.assignmentId,
    version: proposal.assignmentVersion,
    assignmentGeneration: 1,
    slotKind: "PRIMARY_REVIEWER",
    requiredCapability: "actions.review",
    reviewer: actorSummary(),
    state: proposal.assignmentState,
    dueAt: proposal.expiresAt,
    approvalDigest: proposal.approvalDigest,
  };
}

export function providerQuorum(proposal: ProviderControlProposal) {
  const submitted = proposal.state !== "DRAFT";
  const approved = proposal.state === "APPROVED";
  return {
    planDigest: canonicalJsonSha256({
      actionKind: "PROVIDER_CONTROL",
      requiredSlots: submitted ? ["PRIMARY_REVIEWER"] : [],
    }),
    requiredSlots: submitted ? ["PRIMARY_REVIEWER"] : [],
    satisfiedSlots: approved ? ["PRIMARY_REVIEWER"] : [],
    blockingSlots: submitted && !approved ? ["PRIMARY_REVIEWER"] : [],
    conflictSnapshotDigest: canonicalJsonSha256({
      providerId: proposal.target.targetId,
      expectedVersion: proposal.target.expectedVersion,
    }),
    complete: approved,
  };
}

export function providerExecutionAuthorization(
  proposal: ProviderControlProposal,
) {
  if (!proposal.executionId) return null;
  return {
    executionId: proposal.executionId,
    generation: 1,
    stateVersion: 1,
    actionKind: "PROVIDER_CONTROL",
    state: "QUEUED",
    executionDigest: canonicalJsonSha256({
      actionKind: "PROVIDER_CONTROL",
      approvalDigest: proposal.approvalDigest,
      operationId: proposal.payload.providerControl.operationId,
      executionId: proposal.executionId,
    }),
    cancellationGeneration: 0,
    expiresAt: proposal.expiresAt,
  };
}

function providerDecisionSummary(proposal: ProviderControlProposal) {
  if (!proposal.assignmentId || !proposal.decisionId || !proposal.decision)
    return null;
  return {
    recordKind: "DECISION",
    decisionId: proposal.decisionId,
    assignmentId: proposal.assignmentId,
    assignmentGeneration: 1,
    decisionKind: proposal.decision,
    actor: actorSummary(),
    slotKind: "PRIMARY_REVIEWER",
    capability: "actions.review",
    assurance:
      providerControlPolicies[proposal.payload.providerControl.operationId]
        .assurance,
    reasonCode: "PROVIDER_CONTROL_REVIEW",
    reason: "공급자 제어 변경과 버전 결속을 검토했습니다.",
    approvalDigest: proposal.approvalDigest,
    receiptDigest: canonicalJsonSha256({
      proposalId: proposal.proposalId,
      decisionId: proposal.decisionId,
      decision: proposal.decision,
      approvalDigest: proposal.approvalDigest,
    }),
    decidedAt: proposal.updatedAt,
  };
}

export function providerQueueResponse(proposals: ProviderControlProposal[]) {
  const items = proposals.flatMap((proposal) => {
    const assignment = providerAssignment(proposal);
    return assignment
      ? [
          {
            proposal: providerProposalSummary(proposal),
            assignment,
            quorum: providerQuorum(proposal),
            dueAt: assignment.dueAt,
            riskClass: "HIGH",
            href: `/internal/my-work?proposalId=${proposal.proposalId}`,
          },
        ]
      : [];
  });
  return {
    items,
    appliedFilters: {
      actionKind: ["PROVIDER_CONTROL"],
      proposalState: proposals.map((proposal) => proposal.state),
      assignmentState: items.map((item) => item.assignment.state),
      dueBefore: proposals[0]?.expiresAt ?? now(),
      sort: "DUE_ASC",
    },
    asOf: now(),
    nextCursor: "",
    totalApproximate: items.length,
    operationId: "listActionApprovalQueue",
    links: [],
  };
}

export function providerProposalDetail(
  proposal: ProviderControlProposal,
  latestPreview: Record<string, unknown> | null,
) {
  const assignment = providerAssignment(proposal);
  const decision = providerDecisionSummary(proposal);
  const asOf = now();
  return {
    proposal: providerProposalSummary(proposal),
    origin: proposal.origin,
    payload: proposal.payload,
    rationale: proposal.rationale,
    latestPreview,
    assignmentHistory: {
      items: assignment ? [assignment] : [],
      order: "slot-ordinal-asc-generation-asc-assignment-id-asc",
      asOf,
      pageDigest: canonicalJsonSha256(
        assignment ? [assignment.assignmentId] : [],
      ),
      nextCursor: "",
      complete: true,
    },
    decisionHistory: {
      items: decision ? [decision] : [],
      order: "decided-at-asc-decision-id-asc",
      asOf,
      pageDigest: canonicalJsonSha256(decision ? [decision.receiptDigest] : []),
      nextCursor: "",
      complete: true,
    },
    quorum: providerQuorum(proposal),
    executionAuthorization: providerExecutionAuthorization(proposal),
    asOf,
    links: [],
    operationId: "getActionProposal",
  };
}

export function providerExecutionReceipt(proposal: ProviderControlProposal) {
  const authorization = providerExecutionAuthorization(proposal);
  if (
    !authorization ||
    !proposal.executionJobId ||
    !proposal.executionReceiptId
  )
    return null;
  const recordedAt = proposal.updatedAt;
  const providerRequestDigest = canonicalJsonSha256(
    proposal.payload.providerControl,
  );
  const queuedReceiptDigest = canonicalJsonSha256({
    executionId: authorization.executionId,
    jobId: proposal.executionJobId,
    state: "QUEUED",
    providerRequestDigest,
  });
  return {
    authorization,
    binding: {
      schemaVersion: "execution-binding.v1",
      executionId: authorization.executionId,
      generation: 1,
      approvalDigest: proposal.approvalDigest,
      countedDecisionReceiptDigests: [
        canonicalJsonSha256({
          proposalId: proposal.proposalId,
          decisionId: proposal.decisionId,
        }),
      ],
      executorId: "analysis-worker-provider-control",
      targetRequestSha256: providerRequestDigest,
      providerIdempotencyKeySha256: canonicalJsonSha256({
        executionId: authorization.executionId,
        generation: 1,
      }),
      budgetReservationDigest: canonicalJsonSha256({
        amount: 0,
        currency: "KRW",
      }),
      cancellationGeneration: 0,
      expiresAt: proposal.expiresAt,
    },
    attempts: [
      {
        attemptId: proposal.executionJobId,
        ordinal: 1,
        generation: 1,
        fencingToken: 1,
        state: "QUEUED",
        providerIdempotencyKeySha256: canonicalJsonSha256({
          executionId: authorization.executionId,
          generation: 1,
        }),
        providerAcknowledgementSha256: null,
        startedAt: recordedAt,
        finishedAt: null,
        actualCost: null,
        failureCode: null,
      },
    ],
    receipts: [
      {
        receiptId: proposal.executionReceiptId,
        sequence: 1,
        executionId: authorization.executionId,
        generation: 1,
        stateVersion: 1,
        state: "QUEUED",
        providerEvidenceDigest: null,
        reconciliationEvidenceDigest: null,
        recordedAt,
        receiptDigest: queuedReceiptDigest,
      },
    ],
    terminal: false,
    reconciliationRequired: false,
    asOf: now(),
    links: [],
    operationId: "getActionExecutionReceipt",
  };
}
