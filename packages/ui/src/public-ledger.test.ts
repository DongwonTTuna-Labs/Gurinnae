import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  PUBLIC_LEDGER_SCREEN_IDS,
  type PublicLedgerRow,
  type PublicLedgerViewModel,
  publicLedgerActionRowIndex,
  publicLedgerCell,
  publicLedgerForSection,
  publicLedgerOwnsAction,
  publicLedgerRenderState,
  publicLedgerStatusTone,
} from "./public-ledger";

function ledger(
  overrides: Partial<PublicLedgerViewModel> = {},
): PublicLedgerViewModel {
  return {
    screenId: "PUB-003",
    sectionId: "results",
    actionId: "open-case",
    rows: [
      {
        key: "case-1",
        identifier: publicLedgerCell(
          "id",
          "사건 식별자",
          "11000000-0000-4000-8000-000000000001",
        ),
        title: publicLedgerCell("title", "제목", "계약 산출내역 비교"),
        summary: publicLedgerCell("summary", "요약", "공개 자료 대조"),
        kind: publicLedgerCell("objectType", "유형", "사례"),
        status: {
          label: "공개 상태",
          text: "공식 확인",
          tone: "positive",
        },
        metric: publicLedgerCell("revision", "개정본", 3),
        href: "/cases/case-1",
      },
    ],
    ...overrides,
  };
}

function withoutHref(row: PublicLedgerRow): PublicLedgerRow {
  const { href: _href, ...rest } = row;
  return rest;
}

describe("public ledger view model", () => {
  it("closes the component-owned actions over the seven approved ledgers", () => {
    expect(PUBLIC_LEDGER_SCREEN_IDS).toEqual([
      "PUB-001",
      "PUB-002",
      "PUB-003",
      "PUB-007",
      "PUB-009",
      "PUB-011",
      "PUB-018",
    ]);
    expect(publicLedgerOwnsAction("PUB-002", "open-result")).toBe(true);
    expect(publicLedgerOwnsAction("PUB-003", "open-case")).toBe(true);
    expect(publicLedgerOwnsAction("PUB-007", "open-agency")).toBe(true);
    expect(publicLedgerOwnsAction("PUB-009", "open-supplier")).toBe(true);
    expect(publicLedgerOwnsAction("PUB-011", "open-contract")).toBe(true);
    expect(publicLedgerOwnsAction("PUB-018", "open-correction")).toBe(true);
    expect(publicLedgerOwnsAction("PUB-003", "apply-filter")).toBe(false);
    expect(publicLedgerOwnsAction("PUB-001", "open-case")).toBe(false);
  });

  it("prepares display-only cells without retaining raw scalar values", () => {
    const identifier = publicLedgerCell(
      "id",
      "기관 식별자",
      "11000000-0000-4000-8000-000000000001",
    );
    expect(identifier).toEqual({
      label: "기관 식별자",
      text: "11000000…",
      title: "11000000-0000-4000-8000-000000000001",
      copyText: "11000000-0000-4000-8000-000000000001",
    });
    expect(publicLedgerCell("publicState", "공개 상태", "CORRECTED")).toEqual({
      label: "공개 상태",
      text: "정정됨",
    });
    expect(publicLedgerCell("amount", "계약 금액", "125000000")).toEqual({
      label: "계약 금액",
      text: "₩125,000,000",
      secondary: "약 1.25억 원",
    });
    expect(identifier).not.toHaveProperty("value");
  });

  it("accepts only the exact screen, section, action and public detail path", () => {
    const view = ledger();
    const first = view.rows[0];
    if (!first) throw new Error("test fixture must contain a row");
    expect(publicLedgerForSection(view, "PUB-003", "results")).toBe(view);
    expect(publicLedgerActionRowIndex(view)).toBe(0);
    expect(
      publicLedgerActionRowIndex(
        ledger({
          screenId: "PUB-001",
          sectionId: "recent",
          actionId: "open-case",
        }),
      ),
    ).toBe(-1);
    expect(
      publicLedgerForSection(undefined, "PUB-003", "results"),
    ).toBeUndefined();

    expect(() => publicLedgerForSection(view, "PUB-003", "filters")).toThrow(
      "공개 대장 화면 계약 불일치",
    );
    expect(() =>
      publicLedgerForSection(
        ledger({ sectionId: "records" }),
        "PUB-003",
        "results",
      ),
    ).toThrow("공개 대장 런타임 계약 불일치");
    expect(() =>
      publicLedgerForSection(
        ledger({
          rows: [
            {
              ...first,
              href: "https://attacker.invalid/cases/case-1",
            },
          ],
        }),
        "PUB-003",
        "results",
      ),
    ).toThrow("공개 대장 이동 경로 불일치");
  });

  it.each([
    "/agencies/agency-1",
    "/cases/case-1",
    "/contracts/contract-1",
    "/corrections/correction-1",
    "/data",
    "/methodology/rules/rule-1",
    "/sources/source-1",
    "/suppliers/supplier-1",
  ])("keeps every contracted search result path navigable: %s", (href) => {
    const first = ledger().rows[0];
    if (!first) throw new Error("test fixture must contain a row");
    const view = ledger({
      screenId: "PUB-002",
      sectionId: "results",
      actionId: "open-result",
      rows: [{ ...first, href }],
    });
    expect(publicLedgerForSection(view, "PUB-002", "results")).toBe(view);
  });

  it("keeps one action hook on the first verified row and rejects duplicate keys", () => {
    const first = ledger().rows[0];
    if (!first) throw new Error("test fixture must contain a row");
    const view = ledger({
      rows: [
        withoutHref(first),
        { ...first, key: "case-2", href: "/cases/case-2" },
      ],
    });
    expect(publicLedgerActionRowIndex(view)).toBe(1);
    expect(() =>
      publicLedgerForSection(
        ledger({ rows: [first, { ...first }] }),
        "PUB-003",
        "results",
      ),
    ).toThrow("공개 대장 행 식별자 불일치");
  });

  it("derives closed render states and status tones", () => {
    expect(publicLedgerRenderState("success", ledger())).toMatchObject({
      projectionState: "READY",
      showRows: true,
    });
    expect(publicLedgerRenderState("awaiting-query", undefined)).toEqual({
      projectionState: "EMPTY",
      message: "검색어 입력 대기",
      showRows: false,
      alert: false,
    });
    expect(publicLedgerRenderState("error", ledger())).toMatchObject({
      projectionState: "ERROR",
      alert: true,
      showRows: false,
    });
    expect(publicLedgerStatusTone("OFFICIALLY_CONFIRMED")).toBe("positive");
    expect(publicLedgerStatusTone("PUBLISHED_ANOMALY")).toBe("warning");
    expect(publicLedgerStatusTone("RETRACTED")).toBe("critical");
  });

  it("renders the server-owned ledger without a row picker or raw projection", () => {
    const component = readFileSync(
      new URL("./components/sections/PublicLedger.svelte", import.meta.url),
      "utf8",
    );
    const model = readFileSync(
      new URL("./public-ledger.ts", import.meta.url),
      "utf8",
    );
    for (const heading of ["식별자", "제목·요약", "유형", "상태", "핵심 수치"])
      expect(component).toContain(heading);
    expect(component).toContain("runtime.publicLedger");
    expect(component).toContain("data-action-id=");
    expect(component).toContain("status-dot");
    expect(component).not.toContain("<section");
    expect(component).not.toContain('data-component="PublicLedger"');
    expect(component).not.toContain("data-testid={section.test_id}");
    expect(component).not.toContain("<select");
    expect(component).not.toContain("ProjectionValue");
    expect(model).not.toContain("ScreenSectionProjection");
    expect(model).not.toContain("collectionFields");
    expect(model).not.toContain("navigationOptions");
  });
});
