import { describe, expect, it } from "vitest";
import {
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
      ["q", "types", "publicationState", "dateFrom", "dateTo", "sort"],
    ],
    [
      "PUB-003",
      "apply-filter",
      [
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
    ],
    ["INT-003", "submit-search", ["q", "types", "status", "sort"]],
    ["CAS-012", "filter", ["eventType", "actorId", "from", "to", "sort"]],
  ])("declares the exact %s query surface", (screenId, actionId, queryKeys) => {
    const contract = urlFilterContractFor(screenId);

    expect(contract?.actionId).toBe(actionId);
    expect(contract?.queryKeys).toEqual(queryKeys);
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

  it("normalizes the visible comma-separated array control", () => {
    expect(
      urlFilterArrayValues(" REVISION_PUBLISHED, CASE_UPDATED, ,"),
    ).toEqual(["REVISION_PUBLISHED", "CASE_UPDATED"]);
  });

  it("omits a blank scalar control and trims a present value", () => {
    expect(urlFilterScalarValue("  ")).toBeUndefined();
    expect(urlFilterScalarValue("  occurred_asc ")).toBe("occurred_asc");
  });

  it("does not opt unrelated screens into the URL action contract", () => {
    expect(urlFilterContractFor("PUB-001")).toBeUndefined();
    expect(urlFilterContractFor("CAS-011")).toBeUndefined();
  });
});
