export type PublicActionPlacement = Readonly<{
  headerActionIds: readonly string[];
  sectionActionIds: Readonly<Record<string, readonly string[]>>;
  componentActionIds: readonly string[];
  attachmentSectionId?: string;
}>;

type ScreenActions = Readonly<{
  id: string;
  actions: readonly Readonly<{ id: string }>[];
}>;

const placements = {
  "PUB-001": header("search", "browse-cases", "subscribe"),
  "PUB-002": placed(["clear", "download-csv", "download-jsonl"], {}, [
    "submit-search",
    "open-result",
  ]),
  "PUB-003": placed(
    ["subscribe-filter", "download-csv", "download-jsonl"],
    {},
    ["apply-filter", "open-case"],
  ),
  "PUB-004": placed(
    ["copy-citation", "request-correction", "subscribe-case"],
    {},
    ["open-evidence"],
  ),
  "PUB-005": header("view-latest", "compare", "copy-citation"),
  "PUB-006": header("download-json", "download-csv", "view-rule"),
  "PUB-007": placed([], {}, ["open-agency", "apply-filter"]),
  "PUB-008": header("view-contract", "view-case", "subscribe-agency"),
  "PUB-009": placed([], {}, ["open-supplier", "apply-filter"]),
  "PUB-010": header("view-contract", "view-case", "subscribe-supplier"),
  "PUB-011": placed(["download"], {}, ["open-contract", "apply-filter"]),
  "PUB-012": placed(["open-source", "copy-contract-id"], {}, ["open-case"]),
  "PUB-013": header("open-rule", "view-coverage"),
  "PUB-014": header("view-related-cases", "download-rule"),
  "PUB-015": header("open-source", "download-coverage"),
  "PUB-016": header("open-source"),
  "PUB-017": header("view-official", "view-related-rules"),
  "PUB-018": placed(["subscribe"], {}, ["apply-filter", "open-correction"]),
  "PUB-019": header("open-case", "view-old-revision", "copy-citation"),
  "PUB-020": placed(["view-schema", "open-api-docs"], {}, ["download-dataset"]),
  "PUB-021": header("download-openapi", "view-data-policy"),
  "PUB-022": header("view-governance", "contact"),
  "PUB-023": header("download-report", "view-governance"),
  "PUB-024": header("view-editorial-policy", "request-correction"),
  "PUB-025": header("request-correction", "view-history"),
  "PUB-026": placed(["open-correction", "security-report"], {
    form: ["submit-contact"],
  }),
  "PUB-027": placed(
    [],
    { review: ["submit-correction"] },
    ["save-draft"],
    "evidence",
  ),
  "PUB-028": header("download-receipt", "manage-request"),
  "PUB-029": placed([], {}, ["request-verification"]),
  "PUB-030": placed([], { preferences: ["save-preferences", "unsubscribe"] }),
  "PUB-031": header("privacy-contact", "view-history"),
  "PUB-032": header("view-data", "contact"),
  "PUB-033": header("report-accessibility", "request-alternative"),
  "PUB-034": header("retry", "go-home", "view-status"),
  "PUB-035": placed(["contact"], {}, ["queue-donation"]),
} as const satisfies Readonly<Record<string, PublicActionPlacement>>;

export const PUBLIC_ACTION_PLACEMENT_SCREEN_IDS = Object.freeze(
  Object.keys(placements),
);

export function publicActionPlacement(
  screen: ScreenActions,
): PublicActionPlacement | undefined {
  const placement = placements[screen.id as keyof typeof placements];
  if (!placement) {
    if (screen.id.startsWith("PUB-"))
      throw new Error(`미분류 공개 화면 action 계약: ${screen.id}`);
    return undefined;
  }

  const actual = screen.actions.map((action) => action.id);
  const actualDuplicate = duplicate(actual);
  if (actualDuplicate)
    throw new Error(`${screen.id} action 중복: ${actualDuplicate}`);

  const classified = classifiedActionIds(placement);
  const classifiedDuplicate = duplicate(classified);
  if (classifiedDuplicate)
    throw new Error(`${screen.id} action 배치 중복: ${classifiedDuplicate}`);

  const classifiedSet = new Set(classified);
  const actualSet = new Set(actual);
  const unknown = actual.filter((actionId) => !classifiedSet.has(actionId));
  const missing = classified.filter((actionId) => !actualSet.has(actionId));
  if (unknown.length > 0 || missing.length > 0) {
    throw new Error(
      `${screen.id} action 배치 불일치 (미분류: ${list(unknown)}, 계약에 없음: ${list(missing)})`,
    );
  }
  return placement;
}

export function sectionActionIds(
  placement: PublicActionPlacement | undefined,
  sectionId: string,
): readonly string[] {
  return placement?.sectionActionIds[sectionId] ?? [];
}

function header(...headerActionIds: readonly string[]): PublicActionPlacement {
  return placed(headerActionIds);
}

function placed(
  headerActionIds: readonly string[],
  sectionActionIds: Readonly<Record<string, readonly string[]>> = {},
  componentActionIds: readonly string[] = [],
  attachmentSectionId?: string,
): PublicActionPlacement {
  return Object.freeze({
    headerActionIds: Object.freeze([...headerActionIds]),
    sectionActionIds: Object.freeze(sectionActionIds),
    componentActionIds: Object.freeze([...componentActionIds]),
    ...(attachmentSectionId ? { attachmentSectionId } : {}),
  });
}

function classifiedActionIds(
  placement: PublicActionPlacement,
): readonly string[] {
  return [
    ...placement.headerActionIds,
    ...Object.values(placement.sectionActionIds).flat(),
    ...placement.componentActionIds,
  ];
}

function duplicate(values: readonly string[]): string | undefined {
  const seen = new Set<string>();
  for (const value of values) {
    if (seen.has(value)) return value;
    seen.add(value);
  }
  return undefined;
}

function list(values: readonly string[]): string {
  return values.length > 0 ? values.join(", ") : "없음";
}
