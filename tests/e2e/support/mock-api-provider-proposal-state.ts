import { randomUUID } from "node:crypto";
import {
  canonicalJsonSha256,
  type ProviderControlCommand,
  type ProviderControlOperationId,
  type ProviderControlProposal,
  providerControlOperationIds,
  type RelayDataPolicyInput,
  runtime,
} from "./mock-api-state";

type JsonObject = Record<string, unknown>;
type ParseResult =
  | {
      ok: true;
      origin: JsonObject;
      payload: ProviderControlProposal["payload"];
      rationale: JsonObject;
      expiresAt: string;
    }
  | { ok: false; message: string };

const providerOperationSet = new Set<string>(providerControlOperationIds);

function object(value: unknown): JsonObject | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as JsonObject)
    : undefined;
}

function exactKeys(
  value: JsonObject,
  required: readonly string[],
  optional: readonly string[] = [],
) {
  const allowed = new Set([...required, ...optional]);
  return (
    required.every((key) => Object.hasOwn(value, key)) &&
    Object.keys(value).every((key) => allowed.has(key))
  );
}

function text(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function version(value: unknown): value is number {
  return Number.isInteger(value) && typeof value === "number" && value >= 1;
}

function optionalText(value: JsonObject, key: string) {
  return !Object.hasOwn(value, key) || text(value[key]);
}

const processingRegionPattern = /^[A-Z]{2}(?:-[A-Z0-9]{1,12})?$/;
const modelIdPattern = /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,254}$/;
const trackPattern = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const retentionModes = new Set<RelayDataPolicyInput["retentionMode"]>([
  "ZERO_RETENTION",
  "BOUNDED_PROVIDER_RETENTION",
  "LOCAL_ONLY",
]);

function relayDataPolicy(value: unknown): RelayDataPolicyInput | null {
  const policy = object(value);
  if (
    !policy ||
    !exactKeys(policy, [
      "processingRegion",
      "retentionMode",
      "policyVersion",
    ]) ||
    !text(policy.processingRegion) ||
    policy.processingRegion.length > 15 ||
    !processingRegionPattern.test(policy.processingRegion) ||
    !text(policy.retentionMode) ||
    !retentionModes.has(
      policy.retentionMode as RelayDataPolicyInput["retentionMode"],
    ) ||
    !text(policy.policyVersion) ||
    policy.policyVersion.length > 64
  )
    return null;
  return {
    processingRegion: policy.processingRegion,
    retentionMode:
      policy.retentionMode as RelayDataPolicyInput["retentionMode"],
    policyVersion: policy.policyVersion,
  };
}

function parseProviderCommand(value: unknown): ProviderControlCommand | null {
  const command = object(value);
  if (!command || !text(command.operationId)) return null;
  if (!providerOperationSet.has(command.operationId)) return null;
  const operationId = command.operationId as ProviderControlOperationId;
  if (operationId === "disableProviderRouting") {
    if (
      !exactKeys(command, [
        "operationId",
        "providerId",
        "reason",
        "expectedVersion",
      ]) ||
      !text(command.providerId) ||
      !text(command.reason) ||
      !version(command.expectedVersion)
    )
      return null;
    return {
      operationId,
      providerId: command.providerId,
      reason: command.reason,
      expectedVersion: command.expectedVersion,
    };
  }
  if (operationId === "testProviderConnection") {
    if (
      !exactKeys(
        command,
        ["operationId", "providerId", "testModel", "expectedVersion"],
        ["reason"],
      ) ||
      !text(command.providerId) ||
      !text(command.testModel) ||
      !version(command.expectedVersion) ||
      !optionalText(command, "reason")
    )
      return null;
    return {
      operationId,
      providerId: command.providerId,
      testModel: command.testModel,
      expectedVersion: command.expectedVersion,
      ...(text(command.reason) ? { reason: command.reason } : {}),
    };
  }
  if (operationId === "upgradeProviderModel") {
    const hasDataPolicy = Object.hasOwn(command, "dataPolicy");
    const dataPolicy = hasDataPolicy
      ? relayDataPolicy(command.dataPolicy)
      : undefined;
    if (
      !exactKeys(
        command,
        ["operationId", "providerId", "modelId", "expectedVersion", "reason"],
        ["dataPolicy"],
      ) ||
      !text(command.providerId) ||
      !text(command.modelId) ||
      !modelIdPattern.test(command.modelId) ||
      !version(command.expectedVersion) ||
      !text(command.reason) ||
      command.reason.length > 4000 ||
      (hasDataPolicy && !dataPolicy)
    )
      return null;
    return {
      operationId,
      providerId: command.providerId,
      modelId: command.modelId,
      expectedVersion: command.expectedVersion,
      reason: command.reason,
      ...(dataPolicy ? { dataPolicy } : {}),
    };
  }
  if (
    !exactKeys(
      command,
      ["operationId", "providerId", "expectedVersion", "enabled", "reason"],
      ["track"],
    ) ||
    !text(command.providerId) ||
    !version(command.expectedVersion) ||
    typeof command.enabled !== "boolean" ||
    !text(command.reason) ||
    command.reason.length > 4000 ||
    !optionalText(command, "track") ||
    (text(command.track) && !trackPattern.test(command.track))
  )
    return null;
  return {
    operationId,
    providerId: command.providerId,
    expectedVersion: command.expectedVersion,
    enabled: command.enabled,
    reason: command.reason,
    ...(text(command.track) ? { track: command.track } : {}),
  };
}

export function parseProviderProposalCreate(input: JsonObject): ParseResult {
  if (
    !exactKeys(input, [
      "actionKind",
      "origin",
      "draft",
      "rationale",
      "expiresAt",
    ]) ||
    input.actionKind !== "PROVIDER_CONTROL" ||
    !text(input.expiresAt) ||
    Number.isNaN(Date.parse(input.expiresAt))
  )
    return { ok: false, message: "provider proposal envelope is invalid" };
  const origin = object(input.origin);
  const payload = object(input.draft);
  const rationale = object(input.rationale);
  const target = object(payload?.target);
  const payloadRationale = object(payload?.rationale);
  const effect = object(payload?.effect);
  const providerControl = parseProviderCommand(payload?.providerControl);
  if (
    !origin ||
    !payload ||
    !rationale ||
    !target ||
    !payloadRationale ||
    !effect ||
    !providerControl ||
    !exactKeys(payload, [
      "schemaVersion",
      "kind",
      "target",
      "rationale",
      "effect",
      "providerControl",
    ]) ||
    payload.schemaVersion !== "action-payload.v1" ||
    payload.kind !== "PROVIDER_CONTROL" ||
    !exactKeys(target, ["targetType", "targetId", "expectedVersion"]) ||
    target.targetType !== "CAPABILITY" ||
    target.targetId !== providerControl.providerId ||
    target.expectedVersion !== providerControl.expectedVersion ||
    canonicalJsonSha256(rationale) !== canonicalJsonSha256(payloadRationale)
  )
    return { ok: false, message: "provider proposal payload is invalid" };
  return {
    ok: true,
    origin,
    payload: {
      schemaVersion: "action-payload.v1",
      kind: "PROVIDER_CONTROL",
      target: {
        targetType: "CAPABILITY",
        targetId: providerControl.providerId,
        expectedVersion: providerControl.expectedVersion,
      },
      rationale,
      effect,
      providerControl,
    },
    rationale,
    expiresAt: input.expiresAt,
  };
}

export function createProviderProposal(
  parsed: Extract<ParseResult, { ok: true }>,
) {
  const now = new Date().toISOString();
  const proposalId = randomUUID();
  const contentDigest = canonicalJsonSha256(parsed.payload);
  const approvalDigest = canonicalJsonSha256({
    actionKind: "PROVIDER_CONTROL",
    contentDigest,
    origin: parsed.origin,
    rationale: parsed.rationale,
    target: parsed.payload.target,
  });
  const proposal: ProviderControlProposal = {
    proposalId,
    version: 1,
    state: "DRAFT",
    contentDigest,
    approvalDigest,
    target: parsed.payload.target,
    origin: parsed.origin,
    payload: parsed.payload,
    rationale: parsed.rationale,
    expiresAt: parsed.expiresAt,
    createdAt: now,
    updatedAt: now,
    previewId: null,
    previewVersion: null,
    previewDigest: null,
    assignmentId: null,
    assignmentVersion: null,
    assignmentState: null,
    decisionId: null,
    decision: null,
    executionId: null,
    executionJobId: null,
    executionReceiptId: null,
  };
  runtime.providerControlProposals.set(proposalId, proposal);
  observeProviderProposal("createActionProposal", proposal);
  return proposal;
}

export function observeProviderProposal(
  operationId: string,
  proposal: ProviderControlProposal,
) {
  runtime.providerControlEvents.push({
    operationId,
    providerOperationId: proposal.payload.providerControl.operationId,
    proposalId: proposal.proposalId,
    state: proposal.state,
  });
}

export function providerProposalByExecutionId(executionId: string) {
  return [...runtime.providerControlProposals.values()].find(
    (proposal) => proposal.executionId === executionId,
  );
}

export function isProviderControlOperationId(
  value: unknown,
): value is ProviderControlOperationId {
  return typeof value === "string" && providerOperationSet.has(value);
}
