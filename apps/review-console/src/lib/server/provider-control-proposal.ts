import type { RelayProviderAuthority } from "./relay-model-form";

export const PROVIDER_CONTROL_OPERATION_IDS = [
  "disableProviderRouting",
  "testProviderConnection",
  "upgradeProviderModel",
  "setModelAutoUpgrade",
] as const;

export type ProviderControlOperationId =
  (typeof PROVIDER_CONTROL_OPERATION_IDS)[number];

type CapabilityState = "UNCONFIGURED" | "APPROVED" | "SUSPENDED";

type ProposalBuildInput = {
  operationId: ProviderControlOperationId;
  input: Readonly<Record<string, unknown>>;
  authority: Readonly<RelayProviderAuthority>;
  activeModelIds: readonly string[];
  actorId: string;
  now: Date;
};

type ProposalDispatch = {
  operationId: "createActionProposal";
  body: Record<string, unknown>;
};

export type ProposalBuildResult =
  | { ok: true; dispatch: ProposalDispatch }
  | { ok: false; status: 409 | 422; message: string };

const RETENTION_MODES = new Set([
  "ZERO_RETENTION",
  "BOUNDED_PROVIDER_RETENTION",
  "LOCAL_ONLY",
]);
const PROCESSING_REGION = /^[A-Z]{2}(?:-[A-Z0-9]{1,12})?$/;

export function isProviderControlOperationId(
  operationId: string,
): operationId is ProviderControlOperationId {
  return PROVIDER_CONTROL_OPERATION_IDS.some(
    (candidate) => candidate === operationId,
  );
}

export function providerCapabilityState(
  authority: Readonly<RelayProviderAuthority>,
): CapabilityState {
  if (authority.dataPolicyState === "UNCONFIGURED") return "UNCONFIGURED";
  return authority.enabled ? "APPROVED" : "SUSPENDED";
}

export function providerProposalExpiresAt(now: Date): string {
  if (!Number.isFinite(now.getTime())) throw new Error("invalid server clock");
  return new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000).toISOString();
}

export function buildProviderControlProposal(
  request: ProposalBuildInput,
): ProposalBuildResult {
  const reason = nonempty(request.input.reason);
  if (!reason)
    return { ok: false, status: 422, message: "제안 사유를 입력해야 합니다." };
  if (!isUuid(request.actorId))
    return {
      ok: false,
      status: 409,
      message: "현재 로그인 사용자를 제안자로 확인할 수 없습니다.",
    };

  const providerControl = providerControlPayload(request);
  if (!providerControl.ok) return providerControl;
  const currentState = providerCapabilityState(request.authority);
  const rationale = {
    summary: reason,
    evidenceSegmentIds: [],
    unknowns: [],
    alternativesConsidered: [],
    riskNote: reason,
  };
  const effect = providerEffect(request.operationId, currentState);
  const target = {
    targetType: "CAPABILITY",
    targetId: request.authority.providerId,
    expectedVersion: request.authority.expectedVersion,
  };
  return {
    ok: true,
    dispatch: {
      operationId: "createActionProposal",
      body: {
        actionKind: "PROVIDER_CONTROL",
        origin: {
          kind: "HUMAN",
          actorId: request.actorId,
          screenId: "OPS-005",
          reason,
        },
        draft: {
          schemaVersion: "action-payload.v1",
          kind: "PROVIDER_CONTROL",
          target,
          rationale,
          effect,
          providerControl: providerControl.value,
        },
        rationale,
        expiresAt: providerProposalExpiresAt(request.now),
      },
    },
  };
}

type ProviderPayloadResult =
  | { ok: true; value: Record<string, unknown> }
  | { ok: false; status: 422; message: string };

function providerControlPayload(
  request: ProposalBuildInput,
): ProviderPayloadResult {
  const base = {
    operationId: request.operationId,
    providerId: request.authority.providerId,
    expectedVersion: request.authority.expectedVersion,
  };
  const reason = nonempty(request.input.reason);
  if (!reason)
    return { ok: false, status: 422, message: "제안 사유를 입력해야 합니다." };
  switch (request.operationId) {
    case "disableProviderRouting":
      return { ok: true, value: { ...base, reason } };
    case "testProviderConnection": {
      const testModel = selectedActiveModel(
        request.input.testModel,
        request.activeModelIds,
      );
      if (!testModel) return activeModelFailure();
      return { ok: true, value: { ...base, testModel, reason } };
    }
    case "upgradeProviderModel": {
      const modelId = selectedActiveModel(
        request.input.modelId,
        request.activeModelIds,
      );
      if (!modelId) return activeModelFailure();
      const dataPolicy = firstActivationPolicy(request);
      if (!dataPolicy.ok) return dataPolicy;
      return {
        ok: true,
        value: {
          ...base,
          modelId,
          reason,
          ...(dataPolicy.value ? { dataPolicy: dataPolicy.value } : {}),
        },
      };
    }
    case "setModelAutoUpgrade": {
      if (typeof request.input.enabled !== "boolean")
        return {
          ok: false,
          status: 422,
          message: "자동 업그레이드 사용 여부를 선택해야 합니다.",
        };
      const track = optionalNonempty(request.input.track);
      if (track === undefined && request.input.track !== undefined)
        return {
          ok: false,
          status: 422,
          message: "모델 계열을 올바르게 입력해야 합니다.",
        };
      return {
        ok: true,
        value: {
          ...base,
          enabled: request.input.enabled,
          ...(track ? { track } : {}),
          reason,
        },
      };
    }
  }
}

function firstActivationPolicy(
  request: ProposalBuildInput,
):
  | { ok: true; value?: Record<string, unknown> }
  | { ok: false; status: 422; message: string } {
  if (request.authority.dataPolicyState === "CONFIGURED") {
    // A configured provider reuses its persisted policy. Browser fields can
    // neither replace nor clear it through a model proposal.
    return { ok: true };
  }
  const policy = record(request.input.dataPolicy);
  const processingRegion = nonempty(policy?.processingRegion);
  const retentionMode = nonempty(policy?.retentionMode);
  const policyVersion = nonempty(policy?.policyVersion);
  if (
    !processingRegion ||
    !PROCESSING_REGION.test(processingRegion) ||
    !retentionMode ||
    !RETENTION_MODES.has(retentionMode) ||
    !policyVersion
  )
    return {
      ok: false,
      status: 422,
      message: "첫 활성화 데이터 정책을 모두 입력해야 합니다.",
    };
  return {
    ok: true,
    value: { processingRegion, retentionMode, policyVersion },
  };
}

function providerEffect(
  operationId: ProviderControlOperationId,
  currentState: CapabilityState,
) {
  const state = (value: CapabilityState) => ({
    aggregate: "CAPABILITY",
    state: value,
  });
  switch (operationId) {
    case "disableProviderRouting":
      return {
        effectClass: "OPERATIONAL_CONTROL",
        fromState: state(currentState),
        toState: state("SUSPENDED"),
        externalSideEffect: false,
        reversible: true,
        expectedOutcome: "공급자 라우팅 중지",
      };
    case "testProviderConnection":
      return {
        effectClass: "OPERATIONAL_CONTROL",
        fromState: state(currentState),
        toState: state(currentState),
        externalSideEffect: true,
        reversible: false,
        expectedOutcome: "공급자 연결 검증",
      };
    case "upgradeProviderModel":
      return {
        effectClass: "OPERATIONAL_CONTROL",
        fromState: state(currentState),
        toState: state("APPROVED"),
        externalSideEffect: true,
        reversible: true,
        expectedOutcome: "선택 모델 검증 후 공급자 모델 적용",
      };
    case "setModelAutoUpgrade":
      return {
        effectClass: "POLICY_CHANGE",
        fromState: state(currentState),
        toState: state(currentState),
        externalSideEffect: false,
        reversible: true,
        expectedOutcome: "공급자 자동 업그레이드 정책 적용",
      };
  }
}

function selectedActiveModel(
  value: unknown,
  activeModelIds: readonly string[],
): string | undefined {
  const modelId = nonempty(value);
  return modelId && activeModelIds.includes(modelId) ? modelId : undefined;
}

function activeModelFailure(): ProviderPayloadResult {
  return {
    ok: false,
    status: 422,
    message: "활성 relay 모델을 선택해야 합니다.",
  };
}

function record(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function nonempty(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function optionalNonempty(value: unknown): string | null | undefined {
  if (value === undefined || value === null) return null;
  return nonempty(value);
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value,
  );
}
