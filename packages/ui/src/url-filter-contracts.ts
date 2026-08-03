export type UrlFilterScreenId = "PUB-002" | "PUB-003" | "INT-003" | "CAS-012";

export type UrlFilterContract = {
  readonly actionId: string;
  readonly actionLabel: string;
  readonly queryKeys: readonly string[];
  readonly arrayKeys: readonly string[];
};

const URL_FILTER_CONTRACTS: Readonly<
  Record<UrlFilterScreenId, UrlFilterContract>
> = {
  "PUB-002": {
    actionId: "submit-search",
    actionLabel: "검색",
    queryKeys: ["q", "types", "publicationState", "dateFrom", "dateTo", "sort"],
    arrayKeys: ["types", "publicationState"],
  },
  "PUB-003": {
    actionId: "apply-filter",
    actionLabel: "필터 적용",
    queryKeys: [
      "publicationState",
      "agencyId",
      "supplierId",
      "ruleId",
      "publishedFrom",
      "publishedTo",
      "hasResponse",
      "hasCorrection",
      "sort",
    ],
    arrayKeys: ["publicationState"],
  },
  "INT-003": {
    actionId: "submit-search",
    actionLabel: "검색",
    queryKeys: ["q", "types", "status", "sort"],
    arrayKeys: ["types", "status"],
  },
  "CAS-012": {
    actionId: "filter",
    actionLabel: "이벤트 필터",
    queryKeys: ["eventType", "actorId", "from", "to", "sort"],
    arrayKeys: ["eventType"],
  },
};

export function urlFilterContractFor(
  screenId: string,
): UrlFilterContract | undefined {
  return screenId in URL_FILTER_CONTRACTS
    ? URL_FILTER_CONTRACTS[screenId as UrlFilterScreenId]
    : undefined;
}

export function urlFilterScalarValue(value: string): string | undefined {
  const normalized = value.trim();
  return normalized || undefined;
}

export function urlFilterArrayValues(value: string): string[] {
  return value
    .split(",")
    .map((item) => item.trim())
    .filter((item) => item.length > 0);
}

function normalizedValues(values: FormDataEntryValue[]): string[] {
  return values
    .filter((value): value is string => typeof value === "string")
    .map(urlFilterScalarValue)
    .filter((value): value is string => value !== undefined);
}

export function normalizeUrlFilterFormData(
  formData: FormData,
  contract: UrlFilterContract,
): void {
  const allowedKeys = new Set(contract.queryKeys);
  const arrayKeys = new Set(contract.arrayKeys);

  for (const key of [...formData.keys()]) {
    if (!allowedKeys.has(key)) formData.delete(key);
  }

  for (const key of contract.queryKeys) {
    const values = normalizedValues(formData.getAll(key));
    formData.delete(key);

    if (arrayKeys.has(key)) {
      for (const value of values.flatMap(urlFilterArrayValues)) {
        formData.append(key, value);
      }
      continue;
    }

    const value = values[0];
    if (value !== undefined) formData.append(key, value);
  }
}
