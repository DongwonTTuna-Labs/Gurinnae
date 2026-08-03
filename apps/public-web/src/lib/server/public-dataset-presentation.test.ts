import { describe, expect, it } from "vitest";
import { publicDatasetPresentation } from "./public-presentation";

const asOf = "2026-07-30T00:00:00Z";
const redistributionNotice = "이상 징후 기록이며 위법·부패의 확정이 아님";

function datasetCoverage() {
  return {
    dateRange: { label: "2026년" },
    sourceIds: [],
    recordCount: 9,
    knownGaps: [],
    freshness: { asOf, status: "CURRENT" },
  };
}

function datasetPage(items: readonly unknown[], includeSeo = true) {
  return {
    items,
    appliedFilters: {},
    asOf,
    ...(includeSeo
      ? {
          seo: {
            title: "공개 대장 · 구린네",
            description: redistributionNotice,
            openGraphDescription: redistributionNotice,
            canonicalUrl: "/records",
            robots: "index,follow",
          },
        }
      : {}),
  };
}

function datasetRows() {
  return Array.from({ length: 9 }, (_, index) => datasetItem(index + 1));
}

function datasetItem(index: number) {
  return {
    id: `dataset-${index}`,
    title: `공개 데이터셋 ${index}`,
    description: `데이터셋 설명 ${index}`,
    format: "CSV, JSONL",
    coverage: datasetCoverage(),
    license: "공개 이용",
    updatedAt: asOf,
    downloadUrl: `/downloads/dataset-${index}`,
    redistributionNotice,
  };
}

describe("closed public dataset presentation", () => {
  it("keeps the required redistribution notice on every closed dataset card", () => {
    const records = publicDatasetPresentation("PUB-020", {
      listPublicDatasets: datasetPage(datasetRows()),
    });

    expect(records).toHaveLength(9);
    expect(records?.[0]).toEqual({
      id: "dataset-1",
      title: "공개 데이터셋 1",
      description: "데이터셋 설명 1",
      format: "CSV, JSONL",
      license: "공개 이용",
      updatedAt: asOf,
      redistributionNotice,
    });
    expect(records?.[0]).not.toHaveProperty("coverage");
    expect(records?.[0]).not.toHaveProperty("downloadUrl");
  });

  it("fails closed when the item notice or page SEO contract is missing", () => {
    const { redistributionNotice: _notice, ...missingNotice } = datasetItem(1);
    expect(() =>
      publicDatasetPresentation("PUB-020", {
        listPublicDatasets: datasetPage([missingNotice]),
      }),
    ).toThrow();
    expect(() =>
      publicDatasetPresentation("PUB-020", {
        listPublicDatasets: datasetPage([datasetItem(1)], false),
      }),
    ).toThrow();
  });
});
