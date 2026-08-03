import {
  FIXTURE_AS_OF,
  publicAgencyRows,
  publicCaseRows,
  publicContractRows,
  publicCorrectionRows,
  publicSearchRows,
  publicSupplierRows,
} from "./mock-api-public-ledger-fixtures";

type JsonObject = Record<string, unknown>;

function values(url: URL | undefined, name: string) {
  return (
    url?.searchParams.getAll(name).filter((value) => value.length > 0) ?? []
  );
}

function query(url: URL | undefined) {
  return url?.searchParams.get("q")?.trim() ?? "";
}

function page(items: readonly unknown[], appliedFilters: JsonObject) {
  return {
    items,
    totalApproximate: items.length,
    appliedFilters,
    asOf: FIXTURE_AS_OF,
  };
}

/** Builds populated public ledgers without altering generated OpenAPI samples. */
export function publicLedgerResponseBody(
  operationId: string,
  url?: URL,
): JsonObject | undefined {
  switch (operationId) {
    case "listPublicCases":
      return page(publicCaseRows, {
        publicationState: values(url, "publicationState"),
      });
    case "listAgencies":
      return page(publicAgencyRows, {
        q: query(url),
        agencyType: values(url, "agencyType"),
        jurisdiction: url?.searchParams.get("jurisdiction")?.trim() ?? "",
      });
    case "listSuppliers":
      return page(publicSupplierRows, {
        q: query(url),
        businessStatus: values(url, "businessStatus"),
        identityStatus: values(url, "identityStatus"),
      });
    case "listContracts":
      return page(publicContractRows, {
        q: query(url),
        contractStatus: values(url, "contractStatus"),
        procurementMethod: values(url, "procurementMethod"),
      });
    case "listCorrections":
      return page(publicCorrectionRows, {
        publicationState: values(url, "publicationState"),
      });
    case "searchPublicRecords": {
      const searchQuery = query(url);
      return page(searchQuery.length > 0 ? publicSearchRows : [], {
        q: searchQuery,
        types: values(url, "types"),
        publicationState: values(url, "publicationState"),
      });
    }
    default:
      return undefined;
  }
}
