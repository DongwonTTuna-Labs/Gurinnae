export type PublicLedgerFilterScreenId =
  | "PUB-002"
  | "PUB-003"
  | "PUB-007"
  | "PUB-009"
  | "PUB-011"
  | "PUB-018";

export type UrlFilterScreenId =
  | PublicLedgerFilterScreenId
  | "INT-003"
  | "CAS-012";

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
    queryKeys: [
      "q",
      "types",
      "publicationState",
      "agencyId",
      "sidoCode",
      "sigunguCode",
      "dateFrom",
      "dateTo",
      "sort",
    ],
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
      "sidoCode",
      "sigunguCode",
      "publishedFrom",
      "publishedTo",
      "hasResponse",
      "hasCorrection",
      "sort",
    ],
    arrayKeys: ["publicationState"],
  },
  "PUB-007": {
    actionId: "apply-filter",
    actionLabel: "필터 적용",
    queryKeys: ["q", "agencyType", "jurisdiction", "sort"],
    arrayKeys: ["agencyType"],
  },
  "PUB-009": {
    actionId: "apply-filter",
    actionLabel: "필터 적용",
    queryKeys: ["q", "businessStatus", "identityStatus", "sort"],
    arrayKeys: ["businessStatus", "identityStatus"],
  },
  "PUB-011": {
    actionId: "apply-filter",
    actionLabel: "필터 적용",
    queryKeys: [
      "q",
      "agencyId",
      "supplierId",
      "contractStatus",
      "procurementMethod",
      "signedFrom",
      "signedTo",
      "amountMin",
      "amountMax",
      "sort",
    ],
    arrayKeys: ["contractStatus", "procurementMethod"],
  },
  "PUB-018": {
    actionId: "apply-filter",
    actionLabel: "필터 적용",
    queryKeys: ["publicationState", "publishedFrom", "publishedTo", "sort"],
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

const PUBLIC_LEDGER_FILTER_SCREENS: ReadonlySet<string> = new Set([
  "PUB-002",
  "PUB-003",
  "PUB-007",
  "PUB-009",
  "PUB-011",
  "PUB-018",
]);

export function isPublicLedgerFilterScreen(
  screenId: string,
): screenId is PublicLedgerFilterScreenId {
  return PUBLIC_LEDGER_FILTER_SCREENS.has(screenId);
}

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
