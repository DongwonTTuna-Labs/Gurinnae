import { describe, expect, it } from "vitest";
import { buildRelatedPublicCases } from "./related-public-cases";
import type { ScreenSectionProjection } from "./screen-projection";

describe("buildRelatedPublicCases", () => {
  it("projects only a title, Korean status and canonical public case href", () => {
    const projection = relatedProjection([
      record({
        slug: "case-2026-001",
        title: "해솔시 청사 유지보수 계약",
        publicState: "PUBLISHED_ANOMALY",
        summary: "렌더하지 않는 내부 요약",
        href: "https://attacker.invalid/cases/case-2026-001",
      }),
    ]);

    expect(buildRelatedPublicCases(projection)).toEqual([
      {
        title: "해솔시 청사 유지보수 계약",
        status: "이상 징후 게시됨",
        href: "/cases/case-2026-001",
      },
    ]);
  });

  it("accepts a projected case href only when the server verified it", () => {
    const projection = relatedProjection([
      record({
        slug: "bad/slug",
        title: "한빛군 재난 안전 계약",
        publicState: "NEVER_PUBLISHED",
        href: "/cases/case-2026-002",
      }),
    ]);

    expect(
      buildRelatedPublicCases(projection, [
        {
          label: "한빛군 재난 안전 계약",
          href: "/cases/case-2026-002",
        },
      ]),
    ).toEqual([
      {
        title: "한빛군 재난 안전 계약",
        status: "게시 이력 없음",
        href: "/cases/case-2026-002",
      },
    ]);
  });

  it("fails closed for unverified, external and incomplete records", () => {
    const projection = relatedProjection([
      record({
        slug: "bad/slug",
        title: "검증되지 않은 경로",
        publicState: "PUBLISHED_ANOMALY",
        href: "/cases/unverified",
      }),
      record({
        slug: "also/bad",
        title: "외부 경로",
        publicState: "PUBLISHED_ANOMALY",
        href: "https://example.com/cases/external",
      }),
      record({ slug: "case-without-status", title: "상태 없음" }),
    ]);

    expect(
      buildRelatedPublicCases(projection, [
        { label: "외부 경로", href: "https://example.com/cases/external" },
      ]),
    ).toEqual([]);
  });

  it("preserves valid source order after dropping invalid rows", () => {
    const projection = relatedProjection([
      record({
        slug: "invalid/slug",
        title: "제외되는 사건",
        publicState: "PUBLISHED_ANOMALY",
      }),
      record({
        slug: "case-2026-004",
        title: "첫 유효 사건",
        publicState: "PUBLISHED_ANOMALY",
      }),
      record({
        slug: "case-2026-005",
        title: "두 번째 유효 사건",
        publicState: "NEVER_PUBLISHED",
      }),
    ]);

    expect(buildRelatedPublicCases(projection)).toEqual([
      {
        title: "첫 유효 사건",
        status: "이상 징후 게시됨",
        href: "/cases/case-2026-004",
      },
      {
        title: "두 번째 유효 사건",
        status: "게시 이력 없음",
        href: "/cases/case-2026-005",
      },
    ]);
  });

  it("rejects projections from any other screen or section", () => {
    const projection = relatedProjection([
      record({
        slug: "case-2026-003",
        title: "다른 화면의 사건",
        publicState: "PUBLISHED_ANOMALY",
      }),
    ]);

    expect(
      buildRelatedPublicCases({ ...projection, screenId: "PUB-004" }),
    ).toEqual([]);
    expect(
      buildRelatedPublicCases({ ...projection, sectionId: "identity" }),
    ).toEqual([]);
  });
});

function relatedProjection(
  items: ReadonlyArray<ReturnType<typeof record>>,
): ScreenSectionProjection {
  return {
    screenId: "PUB-012",
    sectionId: "related",
    region: "evidence",
    component: "RelatedPublicCases",
    fields: [
      {
        name: "relatedCases",
        label: "관련 사건 목록",
        value: { kind: "list", items, omittedCount: 0 },
        known: true,
        source: "getContract.$.relatedCases",
      },
    ],
    state: "READY",
    errorMessage: null,
    focusTarget: "pub_012__state__success__related",
  };
}

function record(values: Readonly<Record<string, string>>) {
  return {
    kind: "record" as const,
    entries: Object.entries(values).map(([name, value]) => ({
      name,
      label: name,
      value,
    })),
    omittedCount: 0,
  };
}
