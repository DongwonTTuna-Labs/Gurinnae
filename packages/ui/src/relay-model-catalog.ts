export const RELAY_UNPRICED_CAPTION = "단가 미설정: 비용 0으로 기록";

export type RelayModelCatalogRow = {
  modelId: string;
  family: string | null;
  createdAt: string | null;
  active: boolean;
  current: boolean;
  new: boolean;
  adoption: "기록 있음" | "기록 없음";
};

export type RelayModelProviderRow = {
  providerId: string;
  name: string;
  currentModel: string | null;
  enabled: boolean;
  autoUpgrade: boolean;
  autoUpgradeConflict: boolean;
  unpriced: boolean;
};

export type RelayModelCatalogViewModel = {
  models: readonly RelayModelCatalogRow[];
  providers: readonly RelayModelProviderRow[];
  caption: typeof RELAY_UNPRICED_CAPTION;
};

export function relayModelCatalogViewModel(
  value: unknown,
): RelayModelCatalogViewModel | undefined {
  const page = record(value);
  if (
    !page ||
    !Array.isArray(page.items) ||
    !Array.isArray(page.currentProviders)
  )
    return undefined;
  const providers = page.currentProviders.map(providerRow);
  if (providers.some((provider) => provider === undefined)) return undefined;
  const resolvedProviders = providers.filter(
    (provider): provider is RelayModelProviderRow => provider !== undefined,
  );
  const currentModels = new Set(
    resolvedProviders.flatMap((provider) =>
      provider.currentModel ? [provider.currentModel] : [],
    ),
  );
  const models = page.items.map((item) => modelRow(item, currentModels));
  if (models.some((model) => model === undefined)) return undefined;
  return {
    models: models.filter(
      (model): model is RelayModelCatalogRow => model !== undefined,
    ),
    providers: resolvedProviders,
    caption: RELAY_UNPRICED_CAPTION,
  };
}

function modelRow(
  value: unknown,
  currentModels: ReadonlySet<string>,
): RelayModelCatalogRow | undefined {
  const row = record(value);
  if (!row) return undefined;
  const modelId = text(row.modelId);
  const family = nullableText(row.family);
  const createdAt = nullableText(row.createdAt);
  if (
    modelId === undefined ||
    family === undefined ||
    createdAt === undefined ||
    typeof row.active !== "boolean" ||
    typeof row.new !== "boolean"
  )
    return undefined;
  return {
    modelId,
    family,
    createdAt,
    active: row.active,
    current: currentModels.has(modelId),
    new: row.new,
    adoption: row.new ? "기록 없음" : "기록 있음",
  };
}

function providerRow(value: unknown): RelayModelProviderRow | undefined {
  const row = record(value);
  if (!row) return undefined;
  const providerId = text(row.providerId);
  const name = text(row.name);
  const currentModel = nullableText(row.currentModel);
  if (
    providerId === undefined ||
    name === undefined ||
    currentModel === undefined ||
    typeof row.enabled !== "boolean" ||
    typeof row.autoUpgrade !== "boolean" ||
    typeof row.autoUpgradeConflict !== "boolean" ||
    typeof row.unpriced !== "boolean"
  )
    return undefined;
  return {
    providerId,
    name,
    currentModel,
    enabled: row.enabled,
    autoUpgrade: row.autoUpgrade,
    autoUpgradeConflict: row.autoUpgradeConflict,
    unpriced: row.unpriced,
  };
}

function record(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function text(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function nullableText(value: unknown): string | null | undefined {
  return value === null ? null : text(value);
}
