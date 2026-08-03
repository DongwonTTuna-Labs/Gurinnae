import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  isPublicLedgerFilterScreen,
  normalizeUrlFilterFormData,
  urlFilterArrayValues,
  urlFilterContractFor,
  urlFilterScalarValue,
} from "./url-filter-contracts";

describe("URL filter contracts", () => {
  it.each([
    [
      "PUB-002",
      "submit-search",
      [
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
    ],
    [
      "PUB-003",
      "apply-filter",
      [
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
    ],
    ["PUB-007", "apply-filter", ["q", "agencyType", "jurisdiction", "sort"]],
    [
      "PUB-009",
      "apply-filter",
      ["q", "businessStatus", "identityStatus", "sort"],
    ],
    [
      "PUB-011",
      "apply-filter",
      [
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
    ],
    [
      "PUB-018",
      "apply-filter",
      ["publicationState", "publishedFrom", "publishedTo", "sort"],
    ],
    ["INT-003", "submit-search", ["q", "types", "status", "sort"]],
    ["CAS-012", "filter", ["eventType", "actorId", "from", "to", "sort"]],
  ])("declares the exact %s query surface", (screenId, actionId, queryKeys) => {
    const contract = urlFilterContractFor(screenId);

    expect(contract?.actionId).toBe(actionId);
    expect(contract?.queryKeys).toEqual(queryKeys);
  });

  it.each([
    ["PUB-002", ["types", "publicationState"]],
    ["PUB-003", ["publicationState"]],
    ["PUB-007", ["agencyType"]],
    ["PUB-009", ["businessStatus", "identityStatus"]],
    ["PUB-011", ["contractStatus", "procurementMethod"]],
    ["PUB-018", ["publicationState"]],
  ])("declares the exact %s repeated-value facets", (screenId, arrayKeys) => {
    expect(urlFilterContractFor(screenId)?.arrayKeys).toEqual(arrayKeys);
  });

  it("omits blank and non-contract values while expanding array values", () => {
    const contract = urlFilterContractFor("PUB-002");
    expect(contract).toBeDefined();
    if (!contract) return;

    const formData = new FormData();
    formData.append("q", "  계약  ");
    formData.append("types", "case, contract");
    formData.append("types", " agency ");
    formData.append("publicationState", " ");
    formData.append("dateFrom", "");
    formData.append("sort", "updated_desc");
    formData.append("cursor", "must-not-survive");

    normalizeUrlFilterFormData(formData, contract);

    expect([...formData.entries()]).toEqual([
      ["q", "계약"],
      ["types", "case"],
      ["types", "contract"],
      ["types", "agency"],
      ["sort", "updated_desc"],
    ]);
  });

  it("keeps an explicit false boolean and removes route/query identifiers", () => {
    const contract = urlFilterContractFor("PUB-003");
    expect(contract).toBeDefined();
    if (!contract) return;

    const formData = new FormData();
    formData.append("hasResponse", "false");
    formData.append("hasCorrection", "");
    formData.append("cursor", "old-page");
    formData.append("caseId", "path-owned-id");

    normalizeUrlFilterFormData(formData, contract);

    expect([...formData.entries()]).toEqual([["hasResponse", "false"]]);
  });

  it("preserves the closed region code facets", () => {
    const contract = urlFilterContractFor("PUB-003");
    expect(contract).toBeDefined();
    if (!contract) return;

    const formData = new FormData();
    formData.append("sidoCode", " 11 ");
    formData.append("sigunguCode", "11680");
    formData.append("regionCodeVersion", "must-not-survive");

    normalizeUrlFilterFormData(formData, contract);

    expect([...formData.entries()]).toEqual([
      ["sidoCode", "11"],
      ["sigunguCode", "11680"],
    ]);
  });

  it("normalizes the visible comma-separated array control", () => {
    expect(
      urlFilterArrayValues(" REVISION_PUBLISHED, CASE_UPDATED, ,"),
    ).toEqual(["REVISION_PUBLISHED", "CASE_UPDATED"]);
  });

  it("retains only the contract ledger filters and expands array facets", () => {
    const contract = urlFilterContractFor("PUB-011");
    expect(contract).toBeDefined();
    if (!contract) return;

    const formData = new FormData();
    formData.append("q", "  냉난방  ");
    formData.append("contractStatus", "ACTIVE, COMPLETED");
    formData.append("procurementMethod", "OPEN_BID");
    formData.append("signedFrom", "2026-01-01");
    formData.append("cursor", "stale-page");
    formData.append("limit", "100");

    normalizeUrlFilterFormData(formData, contract);

    expect([...formData.entries()]).toEqual([
      ["q", "냉난방"],
      ["contractStatus", "ACTIVE"],
      ["contractStatus", "COMPLETED"],
      ["procurementMethod", "OPEN_BID"],
      ["signedFrom", "2026-01-01"],
    ]);
  });

  it("closes the public ledger filter screen set", () => {
    for (const screenId of [
      "PUB-002",
      "PUB-003",
      "PUB-007",
      "PUB-009",
      "PUB-011",
      "PUB-018",
    ]) {
      expect(isPublicLedgerFilterScreen(screenId)).toBe(true);
    }
    expect(isPublicLedgerFilterScreen("PUB-001")).toBe(false);
    expect(isPublicLedgerFilterScreen("INT-003")).toBe(false);
  });

  it("omits a blank scalar control and trims a present value", () => {
    expect(urlFilterScalarValue("  ")).toBeUndefined();
    expect(urlFilterScalarValue("  occurred_asc ")).toBe("occurred_asc");
  });

  it("does not opt unrelated screens into the URL action contract", () => {
    expect(urlFilterContractFor("PUB-001")).toBeUndefined();
    expect(urlFilterContractFor("CAS-011")).toBeUndefined();
  });

  it("lets the sole PUB-007/PUB-009 search section own one apply-filter form", () => {
    const source = readFileSync(
      new URL(
        "./components/sections/PublicLedgerFilters.svelte",
        import.meta.url,
      ),
      "utf8",
    );
    const branchStart = source.indexOf(
      '{:else if screenId === "PUB-007" || screenId === "PUB-009"}',
    );
    const branchEnd = source.indexOf("\n    {:else}\n", branchStart);
    const branch = source.slice(branchStart, branchEnd);

    expect(branchStart).toBeGreaterThan(-1);
    expect(branchEnd).toBeGreaterThan(branchStart);
    expect(source).toContain(
      '? section.id === "search"\n    : showStateMessage',
    );
    expect(source).toMatch(
      /id=\{ownsNamedAction \? `action-\$\{contract\.actionId\}` : undefined\}/,
    );
    expect(source).toContain(
      "data-action-id={ownsNamedAction ? contract.actionId : undefined}",
    );
    expect(branch.match(/<button\b/g)).toHaveLength(1);
    expect(branch).toContain(
      '<button type="submit">{contract.actionLabel}</button>',
    );
  });
});
