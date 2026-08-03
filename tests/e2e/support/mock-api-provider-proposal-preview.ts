import {
  canonicalJsonSha256,
  type ProviderControlCommand,
  type ProviderControlProposal,
  providerControlPolicies,
} from "./mock-api-state";

function approvalDetail(command: ProviderControlCommand) {
  const reasonDigest =
    "reason" in command && command.reason
      ? { reasonDigest: canonicalJsonSha256(command.reason) }
      : {};
  switch (command.operationId) {
    case "disableProviderRouting":
      return {
        operationId: command.operationId,
        providerId: command.providerId,
        expectedVersion: command.expectedVersion,
        ...reasonDigest,
      };
    case "testProviderConnection":
      return {
        operationId: command.operationId,
        providerId: command.providerId,
        expectedVersion: command.expectedVersion,
        testModel: command.testModel,
        ...reasonDigest,
      };
    case "upgradeProviderModel":
      return {
        operationId: command.operationId,
        providerId: command.providerId,
        expectedVersion: command.expectedVersion,
        modelId: command.modelId,
        ...reasonDigest,
        ...(command.dataPolicy
          ? { dataPolicyDigest: canonicalJsonSha256(command.dataPolicy) }
          : {}),
      };
    case "setModelAutoUpgrade":
      return {
        operationId: command.operationId,
        providerId: command.providerId,
        expectedVersion: command.expectedVersion,
        enabled: command.enabled,
        ...(command.track ? { track: command.track } : {}),
        ...reasonDigest,
      };
  }
}

function approvalSubject(proposal: ProviderControlProposal) {
  const command = proposal.payload.providerControl;
  const operationLabel = {
    disableProviderRouting: "공급자 라우팅 중지",
    testProviderConnection: "공급자 연결 검증",
    upgradeProviderModel: "공급자 모델 업그레이드",
    setModelAutoUpgrade: "모델 자동 업그레이드 설정",
  }[command.operationId];
  const evidenceSetDigest = canonicalJsonSha256([]);
  const expectedEffectDigest = canonicalJsonSha256(proposal.payload.effect);
  const governance = {
    riskClass: "HIGH",
    riskSummary: "승인된 공급자 설정만 버전 경계 아래 변경합니다.",
    policyStatus: "PASS",
    policySummary: "연결 검증과 공급자 정책을 실행 시 다시 확인합니다.",
    conflictStatus: "CLEAR",
    rightsStatus: "NOT_APPLICABLE",
    consentAndSuppressionStatus: "NOT_APPLICABLE",
    cost: {
      kind: "NO_PAID_EFFECT",
      explanation: "승인 자체는 외부 사용량을 만들지 않습니다.",
    },
    expirySummary: proposal.expiresAt,
    governanceDigest: canonicalJsonSha256({
      operationId: command.operationId,
      providerId: command.providerId,
      expectedVersion: command.expectedVersion,
    }),
  };
  return {
    summary: {
      plainLanguageChange: operationLabel,
      objectLabel: command.providerId,
      currentState: String(
        (proposal.payload.effect.fromState as Record<string, unknown> | null)
          ?.state ?? "UNCONFIGURED",
      ),
      expectedState: String(
        (proposal.payload.effect.toState as Record<string, unknown>).state,
      ),
      whyNow: String(proposal.rationale.summary),
      freshness: "CURRENT",
      materialConsequence: String(proposal.payload.effect.expectedOutcome),
    },
    evidence: {
      supporting: [],
      contrary: [],
      unknowns: [],
      investigationSummary: "현재 공급자 버전과 선택된 요청을 결속했습니다.",
      evidenceSetDigest,
      contraryEvidenceSetDigest: evidenceSetDigest,
      uncertaintySetDigest: evidenceSetDigest,
    },
    effect: {
      before: String(
        (proposal.payload.effect.fromState as Record<string, unknown> | null)
          ?.state ?? "UNCONFIGURED",
      ),
      after: String(
        (proposal.payload.effect.toState as Record<string, unknown>).state,
      ),
      durableSuccessDefinition:
        "analysis-worker가 연결 검증과 버전 fence를 통과한 뒤 영수증을 남깁니다.",
      partialOrAmbiguousMeaning:
        "QUEUED는 적용 완료가 아니라 실행 권한과 작업 생성만 뜻합니다.",
      reversible: Boolean(proposal.payload.effect.reversible),
      rollbackOrCompensation: "실패하면 기존 공급자 설정을 유지합니다.",
      expectedEffectDigest,
    },
    destination: {
      kind: "INTERNAL_OBJECT",
      objectLabel: command.providerId,
      owningTeam: "operations",
    },
    exactContent: {
      kind: "STRUCTURED_CHANGE",
      fieldChanges: [operationLabel],
      structuredChangeDigest: canonicalJsonSha256(command),
    },
    governance,
    decisionHelp: {
      question: `${operationLabel} 제안을 승인합니까?`,
      approveLabel: "승인",
      approveConsequence:
        "ExecutionAuthorization과 analysis-worker 작업을 생성합니다.",
      rejectLabel: "거부",
      rejectConsequence: "공급자 설정은 변경되지 않습니다.",
      changesRequiredConsequence: "제안자가 변경 요청을 반영해야 합니다.",
      recuseConsequence: "다른 검토자에게 배정합니다.",
      requiredAssurance: providerControlPolicies[command.operationId].assurance,
      requiredQuorum: ["PRIMARY_REVIEWER"],
      defaultDecision: "NONE",
    },
    details: {
      kind: "PROVIDER_CONTROL",
      providerControl: command,
    },
  };
}

export function buildProviderPreview(
  proposal: ProviderControlProposal,
  previewId: string,
) {
  const command = proposal.payload.providerControl;
  const detail = approvalDetail(command);
  const subject = approvalSubject(proposal);
  const approvalSubjectDigest = canonicalJsonSha256(subject);
  const emptyDigest = canonicalJsonSha256([]);
  const binding = {
    schemaVersion: "approval-binding.v1",
    proposalId: proposal.proposalId,
    proposalVersion: proposal.version,
    actionKind: "PROVIDER_CONTROL",
    originDigest: canonicalJsonSha256(proposal.origin),
    contentDigest: proposal.contentDigest,
    rationaleDigest: canonicalJsonSha256(proposal.rationale),
    targetType: "CAPABILITY",
    targetId: proposal.target.targetId,
    targetVersion: proposal.target.expectedVersion,
    targetDigest: canonicalJsonSha256(proposal.target),
    objectScopeDigest: canonicalJsonSha256({
      targetType: "CAPABILITY",
      targetId: proposal.target.targetId,
    }),
    operationId: command.operationId,
    requiredCapability: providerControlPolicies[command.operationId].capability,
    targetRequestDigest: canonicalJsonSha256(command),
    previewId,
    approvalSubjectDigest,
    evidenceSetDigest: emptyDigest,
    contraryEvidenceSetDigest: emptyDigest,
    uncertaintySetDigest: emptyDigest,
    riskAssessmentDigest: canonicalJsonSha256(subject.governance),
    policySnapshotDigest: canonicalJsonSha256(
      "dataPolicy" in command ? (command.dataPolicy ?? {}) : {},
    ),
    conflictSnapshotDigest: canonicalJsonSha256({
      providerId: command.providerId,
      expectedVersion: command.expectedVersion,
    }),
    expectedEffectDigest: canonicalJsonSha256(proposal.payload.effect),
    reversible: Boolean(proposal.payload.effect.reversible),
    quorumPlanDigest: canonicalJsonSha256(["PRIMARY_REVIEWER"]),
    effectIdempotencyKeySha256: canonicalJsonSha256({
      proposalId: proposal.proposalId,
      version: proposal.version,
      operationId: command.operationId,
    }),
    notBefore: proposal.createdAt,
    expiresAt: proposal.expiresAt,
    actionDetailKind: "PROVIDER_CONTROL",
    actionDetail: { kind: "PROVIDER_CONTROL", providerControl: detail },
    actionDetailDigest: canonicalJsonSha256({
      actionDetailKind: "PROVIDER_CONTROL",
      actionDetail: { kind: "PROVIDER_CONTROL", providerControl: detail },
    }),
  };
  const approvalDigest = canonicalJsonSha256(binding);
  const previewCore = {
    previewId,
    proposalId: proposal.proposalId,
    proposalVersion: proposal.version,
    contentDigest: proposal.contentDigest,
    approvalDigest,
    approvalBinding: binding,
    approvalSubject: subject,
    approvalSubjectDigest,
    policyBlockers: [],
    warnings: [],
    expiresAt: proposal.expiresAt,
  };
  return {
    ...previewCore,
    previewDigest: canonicalJsonSha256(previewCore),
  };
}
