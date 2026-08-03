import { describe, expect, it } from "vitest";
import {
  buildProviderControlProposal,
  PROVIDER_CONTROL_OPERATION_IDS,
  type ProviderControlOperationId,
  providerCapabilityState,
  providerProposalExpiresAt,
} from "./provider-control-proposal";
import type { RelayProviderAuthority } from "./relay-model-form";

const ACTOR_ID = "11111111-1111-4111-8111-111111111111";
const PROVIDER_ID = "22222222-2222-4222-8222-222222222222";
const NOW = new Date("2026-07-29T12:00:00.000Z");
const ACTIVE_MODELS = ["relay-model-current", "relay-model-next"];

const configuredAuthority: RelayProviderAuthority = {
  providerId: PROVIDER_ID,
  expectedVersion: 7,
  currentModel: "relay-model-current",
  enabled: true,
  autoUpgrade: false,
  track: "relay-model-",
  dataPolicyState: "CONFIGURED",
};

const inputs: Record<ProviderControlOperationId, Record<string, unknown>> = {
  disableProviderRouting: {
    providerId: "browser-provider",
    expectedVersion: 999,
    reason: "장애 격리",
  },
  testProviderConnection: {
    providerId: "browser-provider",
    expectedVersion: 999,
    testModel: "relay-model-next",
    reason: "적용 전 연결 검증",
  },
  upgradeProviderModel: {
    providerId: "browser-provider",
    expectedVersion: 999,
    modelId: "relay-model-next",
    reason: "최신 모델 적용 검토",
    dataPolicy: {
      processingRegion: "KR",
      retentionMode: "ZERO_RETENTION",
      policyVersion: "policy-v1",
    },
  },
  setModelAutoUpgrade: {
    providerId: "browser-provider",
    expectedVersion: 999,
    enabled: true,
    track: "relay-model-",
    reason: "최신 모델 자동 적용 검토",
  },
};

const expectedEffects: Record<ProviderControlOperationId, unknown> = {
  disableProviderRouting: {
    effectClass: "OPERATIONAL_CONTROL",
    fromState: { aggregate: "CAPABILITY", state: "APPROVED" },
    toState: { aggregate: "CAPABILITY", state: "SUSPENDED" },
    externalSideEffect: false,
    reversible: true,
    expectedOutcome: "공급자 라우팅 중지",
  },
  testProviderConnection: {
    effectClass: "OPERATIONAL_CONTROL",
    fromState: { aggregate: "CAPABILITY", state: "APPROVED" },
    toState: { aggregate: "CAPABILITY", state: "APPROVED" },
    externalSideEffect: true,
    reversible: false,
    expectedOutcome: "공급자 연결 검증",
  },
  upgradeProviderModel: {
    effectClass: "OPERATIONAL_CONTROL",
    fromState: { aggregate: "CAPABILITY", state: "UNCONFIGURED" },
    toState: { aggregate: "CAPABILITY", state: "APPROVED" },
    externalSideEffect: true,
    reversible: true,
    expectedOutcome: "선택 모델 검증 후 공급자 모델 적용",
  },
  setModelAutoUpgrade: {
    effectClass: "POLICY_CHANGE",
    fromState: { aggregate: "CAPABILITY", state: "APPROVED" },
    toState: { aggregate: "CAPABILITY", state: "APPROVED" },
    externalSideEffect: false,
    reversible: true,
    expectedOutcome: "공급자 자동 업그레이드 정책 적용",
  },
};

describe("provider control proposal dispatch", () => {
  it.each(
    PROVIDER_CONTROL_OPERATION_IDS,
  )("maps %s to one schema-shaped createActionProposal dispatch", (operationId) => {
    const authority =
      operationId === "upgradeProviderModel"
        ? { ...configuredAuthority, dataPolicyState: "UNCONFIGURED" as const }
        : configuredAuthority;
    const result = buildProviderControlProposal({
      operationId,
      input: inputs[operationId],
      authority,
      activeModelIds: ACTIVE_MODELS,
      actorId: ACTOR_ID,
      now: NOW,
    });
    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error(result.message);

    expect(result.dispatch.operationId).toBe("createActionProposal");
    expect(PROVIDER_CONTROL_OPERATION_IDS).not.toContain(
      result.dispatch.operationId,
    );
    const body = result.dispatch.body;
    const draft = asRecord(body.draft);
    const target = asRecord(draft.target);
    const inner = asRecord(draft.providerControl);
    expect(body.actionKind).toBe("PROVIDER_CONTROL");
    expect(draft.schemaVersion).toBe("action-payload.v1");
    expect(draft.kind).toBe("PROVIDER_CONTROL");
    expect(target).toEqual({
      targetType: "CAPABILITY",
      targetId: PROVIDER_ID,
      expectedVersion: 7,
    });
    expect(inner.operationId).toBe(operationId);
    expect(inner.providerId).toBe(PROVIDER_ID);
    expect(inner.expectedVersion).toBe(7);
    expect(draft.effect).toEqual(expectedEffects[operationId]);
    expect(body.rationale).toEqual(draft.rationale);
    expect(body.expiresAt).toBe("2026-08-05T12:00:00.000Z");
    expect(body.origin).toEqual({
      kind: "HUMAN",
      actorId: ACTOR_ID,
      screenId: "OPS-005",
      reason: inputs[operationId].reason,
    });
  });

  it("keeps every legacy request branch closed and adds test version binding", () => {
    const branches = Object.fromEntries(
      PROVIDER_CONTROL_OPERATION_IDS.map((operationId) => {
        const authority =
          operationId === "upgradeProviderModel"
            ? {
                ...configuredAuthority,
                dataPolicyState: "UNCONFIGURED" as const,
              }
            : configuredAuthority;
        const result = buildProviderControlProposal({
          operationId,
          input: inputs[operationId],
          authority,
          activeModelIds: ACTIVE_MODELS,
          actorId: ACTOR_ID,
          now: NOW,
        });
        if (!result.ok) throw new Error(result.message);
        return [
          operationId,
          asRecord(asRecord(result.dispatch.body.draft).providerControl),
        ];
      }),
    );
    expect(branches).toEqual({
      disableProviderRouting: {
        operationId: "disableProviderRouting",
        providerId: PROVIDER_ID,
        expectedVersion: 7,
        reason: "장애 격리",
      },
      testProviderConnection: {
        operationId: "testProviderConnection",
        providerId: PROVIDER_ID,
        expectedVersion: 7,
        testModel: "relay-model-next",
        reason: "적용 전 연결 검증",
      },
      upgradeProviderModel: {
        operationId: "upgradeProviderModel",
        providerId: PROVIDER_ID,
        expectedVersion: 7,
        modelId: "relay-model-next",
        reason: "최신 모델 적용 검토",
        dataPolicy: {
          processingRegion: "KR",
          retentionMode: "ZERO_RETENTION",
          policyVersion: "policy-v1",
        },
      },
      setModelAutoUpgrade: {
        operationId: "setModelAutoUpgrade",
        providerId: PROVIDER_ID,
        expectedVersion: 7,
        enabled: true,
        track: "relay-model-",
        reason: "최신 모델 자동 적용 검토",
      },
    });
  });

  it("derives capability state only from fresh provider authority", () => {
    expect(
      providerCapabilityState({
        ...configuredAuthority,
        dataPolicyState: "UNCONFIGURED",
      }),
    ).toBe("UNCONFIGURED");
    expect(providerCapabilityState(configuredAuthority)).toBe("APPROVED");
    expect(
      providerCapabilityState({ ...configuredAuthority, enabled: false }),
    ).toBe("SUSPENDED");
    expect(providerProposalExpiresAt(NOW)).toBe("2026-08-05T12:00:00.000Z");
  });

  it("reuses configured policy and rejects inactive model or incomplete first policy", () => {
    const configured = buildProviderControlProposal({
      operationId: "upgradeProviderModel",
      input: inputs.upgradeProviderModel,
      authority: configuredAuthority,
      activeModelIds: ACTIVE_MODELS,
      actorId: ACTOR_ID,
      now: NOW,
    });
    if (!configured.ok) throw new Error(configured.message);
    expect(
      asRecord(asRecord(configured.dispatch.body.draft).providerControl),
    ).not.toHaveProperty("dataPolicy");

    for (const input of [
      { ...inputs.upgradeProviderModel, modelId: "inactive-model" },
      { ...inputs.upgradeProviderModel, dataPolicy: undefined },
      {
        ...inputs.upgradeProviderModel,
        dataPolicy: {
          processingRegion: "ap-northeast-2",
          retentionMode: "ZERO_RETENTION",
          policyVersion: "policy-v1",
        },
      },
    ]) {
      const result = buildProviderControlProposal({
        operationId: "upgradeProviderModel",
        input,
        authority: {
          ...configuredAuthority,
          dataPolicyState: "UNCONFIGURED",
        },
        activeModelIds: ACTIVE_MODELS,
        actorId: ACTOR_ID,
        now: NOW,
      });
      expect(result.ok).toBe(false);
      if (result.ok) throw new Error("invalid proposal unexpectedly built");
      expect(result.status).toBe(422);
    }
  });
});

function asRecord(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    throw new Error("expected record");
  return value as Record<string, unknown>;
}
