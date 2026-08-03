import { describe, expect, it } from "vitest";
import { buildRowSelectionNavigationOptions } from "./row-selection-navigation";

type MappingCase = Readonly<{
  screenId: string;
  actionId: string;
  data: Record<string, unknown>;
  label: string;
  href: string;
}>;

const cases: readonly MappingCase[] = [
  {
    screenId: "PUB-007",
    actionId: "open-agency",
    data: {
      listAgencies: {
        items: [{ name: "감사원", href: "/agencies/board-of-audit" }],
      },
    },
    label: "감사원",
    href: "/agencies/board-of-audit",
  },
  {
    screenId: "PUB-008",
    actionId: "view-contract",
    data: {
      listAgencyContracts: {
        items: [
          {
            contractNumber: "C-100",
            title: "공개 계약",
            href: "/contracts/contract-100",
          },
        ],
      },
    },
    label: "C-100 · 공개 계약",
    href: "/contracts/contract-100",
  },
  {
    screenId: "PUB-009",
    actionId: "open-supplier",
    data: {
      listSuppliers: {
        items: [{ name: "공급 업체", href: "/suppliers/supplier-100" }],
      },
    },
    label: "공급 업체",
    href: "/suppliers/supplier-100",
  },
  {
    screenId: "PUB-010",
    actionId: "view-contract",
    data: {
      listSupplierContracts: {
        items: [{ title: "업체 계약", href: "/contracts/contract-200" }],
      },
    },
    label: "업체 계약",
    href: "/contracts/contract-200",
  },
  {
    screenId: "PUB-011",
    actionId: "open-contract",
    data: {
      listContracts: {
        items: [{ title: "계약 대장 항목", href: "/contracts/contract-300" }],
      },
    },
    label: "계약 대장 항목",
    href: "/contracts/contract-300",
  },
  {
    screenId: "PUB-012",
    actionId: "open-source",
    data: {
      getContract: {
        sourceDocuments: [
          {
            sourceId: "pps",
            externalId: "notice-100",
            canonicalUrl: "https://records.example/notice/100",
          },
        ],
      },
    },
    label: "pps · notice-100",
    href: "https://records.example/notice/100",
  },
  {
    screenId: "PUB-013",
    actionId: "open-rule",
    data: {
      listRules: {
        items: [
          { ruleId: "unit-price", name: "단가 비교", activeVersion: "3" },
        ],
      },
    },
    label: "단가 비교 · 3",
    href: "/methodology/rules/unit-price",
  },
  {
    screenId: "PUB-015",
    actionId: "open-source",
    data: {
      getCoverage: {
        sources: [{ sourceId: "pps", displayName: "나라장터" }],
      },
    },
    label: "나라장터",
    href: "/sources/pps",
  },
  {
    screenId: "PUB-016",
    actionId: "open-source",
    data: {
      listSourceStatus: {
        items: [{ sourceId: "pps", displayName: "나라장터" }],
      },
    },
    label: "나라장터",
    href: "/sources/pps",
  },
  {
    screenId: "PUB-018",
    actionId: "open-correction",
    data: {
      listCorrections: {
        items: [
          {
            summary: "금액 표기 정정",
            href: "/corrections/correction-100",
          },
        ],
      },
    },
    label: "금액 표기 정정",
    href: "/corrections/correction-100",
  },
  {
    screenId: "PUB-019",
    actionId: "open-case",
    data: { getCorrection: { data: { caseSlug: "case-100" } } },
    label: "case-100",
    href: "/cases/case-100",
  },
  {
    screenId: "INT-001",
    actionId: "open-task",
    data: {
      getInternalDashboard: {
        myTasks: [
          {
            title: "사건 검토",
            href: "/internal/cases/case-100/review",
          },
        ],
        overdueTasks: [],
      },
    },
    label: "사건 검토",
    href: "/internal/cases/case-100/review",
  },
  {
    screenId: "INT-004",
    actionId: "open",
    data: {
      listInternalNotifications: {
        items: [
          {
            title: "검토 요청",
            href: "/internal/review/review-100",
          },
        ],
      },
    },
    label: "검토 요청",
    href: "/internal/review/review-100",
  },
  {
    screenId: "RULE-001",
    actionId: "open-rule",
    data: {
      listInternalRules: {
        items: [{ ruleId: "unit-price", version: "3", name: "단가 비교" }],
      },
    },
    label: "단가 비교 · 3",
    href: "/internal/rules/unit-price/versions/3",
  },
];

describe("row-selection navigation options", () => {
  it.each(cases)("maps $screenId to one server-owned $actionId option", ({
    screenId,
    actionId,
    data,
    label,
    href,
  }) => {
    expect(buildRowSelectionNavigationOptions(screenId, data)).toEqual({
      [actionId]: [{ label, href }],
    });
  });

  it("deduplicates the same task across current and overdue collections", () => {
    const task = {
      title: "사건 검토",
      href: "/internal/cases/case-100/review",
    };
    expect(
      buildRowSelectionNavigationOptions("INT-001", {
        getInternalDashboard: { myTasks: [task], overdueTasks: [task] },
      })["open-task"],
    ).toEqual([{ label: task.title, href: task.href }]);
  });

  it.each([
    ["PUB-007", { listAgencies: { items: [] } }],
    [
      "PUB-011",
      {
        listContracts: {
          items: [
            { title: "외부", href: "https://untrusted.example/contracts/1" },
          ],
        },
      },
    ],
    [
      "PUB-012",
      {
        getContract: {
          sourceDocuments: [
            {
              sourceId: "pps",
              externalId: "1",
              canonicalUrl: "http://records.example/1",
            },
          ],
        },
      },
    ],
    [
      "INT-004",
      {
        listInternalNotifications: {
          items: [{ title: "외부", href: "//untrusted.example/internal" }],
        },
      },
    ],
    [
      "INT-004",
      {
        listInternalNotifications: {
          items: [{ title: "없는 화면", href: "/internal/not-real/1" }],
        },
      },
    ],
    [
      "INT-004",
      {
        listInternalNotifications: {
          items: [{ title: "경로 탈출", href: "/internal/cases/../dashboard" }],
        },
      },
    ],
    [
      "RULE-001",
      {
        listInternalRules: {
          items: [{ ruleId: "rule/escape", version: "1", name: "위험" }],
        },
      },
    ],
  ] as const)("fails closed for %s invalid or empty candidates", (screenId, data) => {
    expect(buildRowSelectionNavigationOptions(screenId, data)).toEqual({});
  });

  it("does not expose operation data for screens outside the closed map", () => {
    expect(
      buildRowSelectionNavigationOptions("PUB-001", {
        listAgencies: {
          items: [{ name: "기관", href: "/agencies/agency-1" }],
        },
      }),
    ).toEqual({});
  });
});
