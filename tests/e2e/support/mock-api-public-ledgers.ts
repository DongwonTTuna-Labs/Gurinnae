import {
  FIXTURE_AS_OF,
  publicAgencyRows,
  publicCaseRows,
  publicContractRows,
  publicCorrectionRows,
  publicSearchRows,
  publicSourceRows,
  publicSupplierRows,
} from "./mock-api-public-ledger-fixtures";
import {
  PUBLIC_SEARCH_AWAITING_QUERY_DESCRIPTION,
  publicSeo,
} from "./mock-api-public-notices";

type JsonObject = Record<string, unknown>;

function values(url: URL | undefined, name: string) {
  return (
    url?.searchParams.getAll(name).filter((value) => value.length > 0) ?? []
  );
}

function query(url: URL | undefined) {
  return url?.searchParams.get("q")?.trim() ?? "";
}

function page(
  items: readonly unknown[],
  appliedFilters: JsonObject,
  title: string,
  canonicalUrl: string,
  descriptions: readonly string[] = noticesFor(items),
) {
  return {
    items,
    totalApproximate: items.length,
    appliedFilters,
    asOf: FIXTURE_AS_OF,
    seo: publicSeo(title, canonicalUrl, descriptions),
  };
}

/** Builds populated public ledgers without altering generated OpenAPI samples. */
export function publicLedgerResponseBody(
  operationId: string,
  url?: URL,
): JsonObject | undefined {
  switch (operationId) {
    case "listPublicCases":
      return page(
        publicCaseRows,
        {
          publicationState: values(url, "publicationState"),
        },
        "사례 대장",
        "/cases",
      );
    case "listAgencies":
      return page(
        publicAgencyRows,
        {
          q: query(url),
          agencyType: values(url, "agencyType"),
          jurisdiction: url?.searchParams.get("jurisdiction")?.trim() ?? "",
        },
        "기관 대장",
        "/agencies",
      );
    case "listSuppliers":
      return page(
        publicSupplierRows,
        {
          q: query(url),
          businessStatus: values(url, "businessStatus"),
          identityStatus: values(url, "identityStatus"),
        },
        "업체 대장",
        "/suppliers",
      );
    case "listContracts":
      return page(
        publicContractRows,
        {
          q: query(url),
          contractStatus: values(url, "contractStatus"),
          procurementMethod: values(url, "procurementMethod"),
        },
        "계약 대장",
        "/contracts",
      );
    case "listCorrections":
      return page(
        publicCorrectionRows,
        {
          publicationState: values(url, "publicationState"),
        },
        "정정 대장",
        "/corrections",
      );
    case "listSourceStatus":
      return page(
        publicSourceRows,
        { status: values(url, "status") },
        "데이터 출처 대장",
        "/sources",
      );
    case "searchPublicRecords": {
      const searchQuery = query(url);
      const items = searchQuery.length > 0 ? publicSearchRows : [];
      return page(
        items,
        {
          q: searchQuery,
          types: values(url, "types"),
          publicationState: values(url, "publicationState"),
        },
        "통합 검색",
        "/search",
        searchQuery.length > 0
          ? noticesFor(items)
          : [PUBLIC_SEARCH_AWAITING_QUERY_DESCRIPTION],
      );
    }
    default:
      return undefined;
  }
}

function noticesFor(items: readonly unknown[]): string[] {
  return items.flatMap((value) => {
    if (!value || typeof value !== "object" || Array.isArray(value)) return [];
    const item = value as JsonObject;
    return [item.nonConclusion, item.interpretationNotice].flatMap((notice) =>
      typeof notice === "string" && notice.trim() ? [notice] : [],
    );
  });
}
