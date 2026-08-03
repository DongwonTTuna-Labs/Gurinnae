import type { RuntimeField } from "@gurine/config";

const RELAY_MODEL_MUTATIONS = new Set([
  "upgradeProviderModel",
  "setModelAutoUpgrade",
]);
const PROVIDER_CONTROL_OPERATIONS = new Set([
  "disableProviderRouting",
  "testProviderConnection",
  ...RELAY_MODEL_MUTATIONS,
]);
export const FIRST_RELAY_DATA_POLICY_CAPTION = "첫 활성화 데이터 정책";

export type RelayProviderAuthority = {
  providerId: string;
  expectedVersion: number;
  currentModel: string | null;
  enabled: boolean;
  autoUpgrade: boolean;
  track: string | null;
  dataPolicyState: "UNCONFIGURED" | "CONFIGURED";
};

export type RelayModelFormContext = {
  preset: Readonly<{ providerId: string; expectedVersion: number }>;
  authority: Readonly<RelayProviderAuthority>;
  activeModelIds: readonly string[];
  requiresDataPolicy: boolean;
  suggestedTrack?: string;
};

export function isProviderControlOperation(operationId: string): boolean {
  return PROVIDER_CONTROL_OPERATIONS.has(operationId);
}

export function isRelayModelMutation(operationId: string): boolean {
  return RELAY_MODEL_MUTATIONS.has(operationId);
}

export function relayModelFormContext(
  data: Record<string, unknown>,
): RelayModelFormContext | undefined {
  const page = record(data.listRelayModels) ?? data;
  const providers = records(page.currentProviders).filter(
    (provider) =>
      nonempty(provider.providerId) !== undefined &&
      typeof provider.version === "number" &&
      Number.isSafeInteger(provider.version) &&
      provider.version >= 1,
  );
  if (providers.length !== 1) return undefined;

  const provider = providers[0];
  if (!provider) return undefined;
  const providerId = nonempty(provider.providerId);
  const expectedVersion = provider.version;
  const currentModel = nullableNonempty(provider.currentModel);
  const track = nullableNonempty(provider.track);
  const dataPolicyState = provider.dataPolicyState;
  if (
    providerId === undefined ||
    typeof expectedVersion !== "number" ||
    typeof provider.enabled !== "boolean" ||
    typeof provider.autoUpgrade !== "boolean" ||
    (dataPolicyState !== "UNCONFIGURED" && dataPolicyState !== "CONFIGURED") ||
    currentModel === undefined ||
    track === undefined
  )
    return undefined;

  const items = records(page.items);
  const activeModelIds = [
    ...new Set(
      items.flatMap((item) => {
        const modelId = nonempty(item.modelId);
        return item.active === true && modelId ? [modelId] : [];
      }),
    ),
  ];
  const currentCatalogItem = currentModel
    ? items.find((item) => item.modelId === currentModel)
    : undefined;
  const suggestedTrack = track ?? nonempty(currentCatalogItem?.track);

  return {
    preset: { providerId, expectedVersion },
    authority: {
      providerId,
      expectedVersion,
      currentModel,
      enabled: provider.enabled,
      autoUpgrade: provider.autoUpgrade,
      track,
      dataPolicyState,
    },
    activeModelIds,
    requiresDataPolicy: dataPolicyState === "UNCONFIGURED",
    ...(suggestedTrack ? { suggestedTrack } : {}),
  };
}

export function relayModelActionPreset(
  operationId: string | undefined,
  data: Record<string, unknown>,
): Record<string, unknown> {
  if (!operationId || !isProviderControlOperation(operationId)) return {};
  return { ...(relayModelFormContext(data)?.preset ?? {}) };
}

export function decorateRelayModelFields(
  operationId: string | undefined,
  fields: readonly RuntimeField[],
  data: Record<string, unknown>,
): RuntimeField[] {
  if (!operationId || !isProviderControlOperation(operationId))
    return [...fields];
  const context = relayModelFormContext(data);
  return fields.map((field) => {
    if (!context && ["providerId", "expectedVersion"].includes(field.name))
      return { ...field, readonly: true };
    if (field.name === "reason") return { ...field, required: true };
    if (operationId === "testProviderConnection" && field.name === "testModel")
      return { ...field, options: context?.activeModelIds ?? [] };
    if (operationId === "upgradeProviderModel" && field.name === "modelId")
      return { ...field, options: context?.activeModelIds ?? [] };
    if (
      operationId === "upgradeProviderModel" &&
      field.payloadPath?.[0] === "dataPolicy" &&
      context?.requiresDataPolicy
    )
      return { ...field, required: true };
    if (
      operationId === "setModelAutoUpgrade" &&
      field.name === "track" &&
      context?.suggestedTrack
    )
      return {
        ...field,
        value: context.suggestedTrack,
        readonly: false,
      };
    return field;
  });
}

export function relayModelFormCaption(
  operationId: string | undefined,
  fields: readonly RuntimeField[],
): string | undefined {
  if (operationId !== "upgradeProviderModel") return undefined;
  const requiredPolicyFields = new Set(
    fields
      .filter(
        (field) => field.payloadPath?.[0] === "dataPolicy" && field.required,
      )
      .map((field) => field.name),
  );
  return ["processingRegion", "retentionMode", "policyVersion"].every((name) =>
    requiredPolicyFields.has(name),
  )
    ? FIRST_RELAY_DATA_POLICY_CAPTION
    : undefined;
}

function records(value: unknown): Record<string, unknown>[] {
  return Array.isArray(value)
    ? value.filter(
        (item): item is Record<string, unknown> => record(item) !== undefined,
      )
    : [];
}

function record(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function nonempty(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function nullableNonempty(value: unknown): string | null | undefined {
  if (value === null || value === undefined) return null;
  return nonempty(value);
}
