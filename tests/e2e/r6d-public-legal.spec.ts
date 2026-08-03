import { expect, test } from "@playwright/test";

const publicBase = "http://127.0.0.1:29101";
const sectionNonConclusion = "이상 징후 기록이며 위법·부패의 확정이 아님";
const operationalInterpretation =
  "이 상태는 자료의 수집·공개·검토 상태이며 위법성이나 부패 여부에 대한 판단이 아닙니다.";

test("[R6D-PUBLIC-NOTICE-001] List and search render one section notice while retaining row status", async ({
  page,
}) => {
  for (const [path, kind] of [
    ["/", "NON_CONCLUSION"],
    ["/cases", "NON_CONCLUSION"],
    ["/agencies", "INTERPRETATION"],
    ["/suppliers", "INTERPRETATION"],
    ["/contracts", "INTERPRETATION"],
    ["/corrections", "NON_CONCLUSION"],
  ] as const) {
    await page.goto(`${publicBase}${path}`, { waitUntil: "networkidle" });
    const statusCells = page.locator(".public-ledger tbody tr td.status");
    expect(
      await statusCells.count(),
      `${path} 공개 대장 행 수`,
    ).toBeGreaterThanOrEqual(8);
    const sectionNotice = page.locator(
      ".public-ledger > .public-section-status-notice > .public-status-notice",
    );
    if (path === "/") {
      await expect(sectionNotice).toHaveCount(0);
      await expect(page.locator(".home-safety")).toHaveText(
        "자동 부패 판정기가 아닙니다 — 가격 차이나 반복 계약은 조사 신호일 뿐 위법·비리를 의미하지 않습니다.",
      );
    } else {
      await expect(sectionNotice).toHaveCount(1);
      await expect(sectionNotice).toHaveAttribute("data-notice-kind", kind);
      await expect(sectionNotice.locator("span")).toHaveText(
        kind === "NON_CONCLUSION"
          ? sectionNonConclusion
          : operationalInterpretation,
      );
    }
    for (const cell of await statusCells.all()) {
      await expect(cell.locator(".status-value")).toHaveCount(1);
      await expect(cell.locator(".public-status-notice")).toHaveCount(0);
    }
  }

  await page.goto(`${publicBase}/`, { waitUntil: "networkidle" });
  await expect(
    page.locator(
      'main#main-content .public-status-notice[data-notice-kind="NON_CONCLUSION"]',
    ),
  ).toHaveCount(1);

  await page.goto(`${publicBase}/search?q=${encodeURIComponent("계약")}`, {
    waitUntil: "networkidle",
  });
  const searchNotice = page.locator(
    '.public-ledger > .public-section-status-notice > .public-status-notice[data-notice-kind="NON_CONCLUSION"]',
  );
  await expect(searchNotice).toHaveCount(1);
  await expect(searchNotice.locator("span")).toHaveText(sectionNonConclusion);
  await expect(
    page.locator(".public-ledger tbody tr td.status > .public-status-notice"),
  ).toHaveCount(0);
});

test("[R6D-PUBLIC-NOTICE-002] Seven public details render their exact notice kind", async ({
  page,
}) => {
  for (const [screenId, path, kind, label] of [
    ["PUB-004", "/cases/synthetic-record", "NON_CONCLUSION", "비확정 고지"],
    [
      "PUB-005",
      "/cases/synthetic-record/revisions/3",
      "NON_CONCLUSION",
      "비확정 고지",
    ],
    [
      "PUB-006",
      "/cases/synthetic-record/reproduce",
      "NON_CONCLUSION",
      "비확정 고지",
    ],
    ["PUB-008", "/agencies/synthetic-record", "INTERPRETATION", "상태 해석"],
    ["PUB-010", "/suppliers/synthetic-record", "INTERPRETATION", "상태 해석"],
    [
      "PUB-012",
      "/contracts/80000000-0000-4000-8000-000000000001",
      "INTERPRETATION",
      "상태 해석",
    ],
    [
      "PUB-019",
      "/corrections/80000000-0000-4000-8000-000000000001",
      "NON_CONCLUSION",
      "비확정 고지",
    ],
  ] as const) {
    await page.goto(`${publicBase}${path}`, { waitUntil: "networkidle" });
    await expect(page.locator("main#main-content")).toHaveAttribute(
      "data-screen-id",
      screenId,
    );
    await expect(page.locator(".error-summary")).toHaveCount(0);
    const context =
      screenId === "PUB-004"
        ? page.locator(".public-case-heading > .public-detail-status-context")
        : page.locator("main#main-content > .public-detail-status-context");
    await expect(context).toHaveCount(1);
    const notice = context.locator(":scope > .public-status-notice");
    await expect(notice).toHaveCount(1);
    await expect(notice).toHaveAttribute("data-notice-kind", kind);
    await expect(notice.locator("strong")).toHaveText(label);
    expect(
      (await notice.locator("span").innerText()).trim().length,
    ).toBeGreaterThan(0);
    if (screenId !== "PUB-006") {
      await expect(context.locator("dl > div")).toHaveCount(
        screenId === "PUB-004" ? 1 : 2,
      );
      expect(
        (await context.getAttribute("data-public-subject"))?.trim().length,
      ).toBeGreaterThan(0);
      expect(
        (await context.getAttribute("data-public-status"))?.trim().length,
      ).toBeGreaterThan(0);
      if (screenId === "PUB-004") {
        await expect(page.locator(".public-case-heading > h1")).toHaveText(
          (await context.getAttribute("data-public-subject")) ?? "",
        );
      }
    } else {
      await expect(context.locator("dl > div")).toHaveCount(1);
      expect(
        (await context.getAttribute("data-public-subject"))?.trim().length,
      ).toBeGreaterThan(0);
      await expect(context).not.toHaveAttribute("data-public-status");
    }
  }
});

test("[R6D-PUBLIC-NOTICE-003] Home corrections render one section notice and retain every row status", async ({
  page,
}) => {
  await page.goto(`${publicBase}/`, { waitUntil: "networkidle" });
  const rows = page.locator("#corrections .public-corrections li");
  expect(await rows.count()).toBeGreaterThanOrEqual(3);
  const sectionNotice = page.locator(
    '#corrections .public-corrections > .public-section-status-notice > .public-status-notice[data-notice-kind="NON_CONCLUSION"]',
  );
  await expect(sectionNotice).toHaveCount(1);
  await expect(sectionNotice.locator("span")).toHaveText(sectionNonConclusion);
  for (const row of await rows.all()) {
    await expect(row.locator(".correction-status")).toHaveCount(1);
    await expect(row.locator(".public-status-notice")).toHaveCount(0);
  }
});

test("[R6D-PUBLIC-NOTICE-004] Related-case summaries render one section notice and retain every row status", async ({
  page,
}) => {
  for (const path of [
    "/agencies/synthetic-record",
    "/suppliers/synthetic-record",
  ] as const) {
    await page.goto(`${publicBase}${path}`, { waitUntil: "networkidle" });
    const rows = page.locator("#cases .related-public-cases li");
    expect(await rows.count(), `${path} 관련 공개 사건 행 수`).toBeGreaterThan(
      0,
    );
    const sectionNotice = page.locator(
      '#cases .related-public-cases > .public-section-status-notice > .public-status-notice[data-notice-kind="NON_CONCLUSION"]',
    );
    await expect(sectionNotice).toHaveCount(1);
    await expect(sectionNotice.locator("span")).toHaveText(
      sectionNonConclusion,
    );
    for (const row of await rows.all()) {
      await expect(row.locator(".case-status")).toHaveCount(1);
      await expect(row.locator(".public-status-notice")).toHaveCount(0);
    }
  }
});

test("[R6D-PUBLIC-NOTICE-005] Target public pages stay within the 1440x900 G10 budget", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  for (const [screenId, path] of [
    ["PUB-001", "/"],
    ["PUB-004", "/cases/synthetic-record"],
    ["PUB-012", "/contracts/80000000-0000-4000-8000-000000000001"],
  ] as const) {
    await page.goto(`${publicBase}${path}`, { waitUntil: "networkidle" });
    await page.evaluate(() => document.fonts.ready);
    const measurement = await page.evaluate(() => ({
      scrollHeight: document.documentElement.scrollHeight,
      viewportHeight: window.innerHeight,
    }));
    expect(
      measurement.scrollHeight / measurement.viewportHeight,
      `${screenId} G10 ${measurement.scrollHeight}/${measurement.viewportHeight}`,
    ).toBeLessThanOrEqual(1.8);
  }
});

for (const [screenId, path, canonicalPath] of [
  ["PUB-001", "/", "/"],
  ["PUB-002", `/search?q=${encodeURIComponent("계약")}`, "/search"],
  ["PUB-003", "/cases", "/cases"],
  ["PUB-004", "/cases/synthetic-record", "/cases/synthetic-record"],
  [
    "PUB-005",
    "/cases/synthetic-record/revisions/3",
    "/cases/synthetic-record/revisions/3",
  ],
  [
    "PUB-006",
    "/cases/synthetic-record/reproduce",
    "/cases/synthetic-record/reproduce",
  ],
  ["PUB-007", "/agencies", "/agencies"],
  ["PUB-008", "/agencies/synthetic-record", "/agencies/synthetic-record"],
  ["PUB-009", "/suppliers", "/suppliers"],
  ["PUB-010", "/suppliers/synthetic-record", "/suppliers/synthetic-record"],
  ["PUB-011", "/contracts", "/contracts"],
  [
    "PUB-012",
    "/contracts/80000000-0000-4000-8000-000000000001",
    "/contracts/80000000-0000-4000-8000-000000000001",
  ],
  [
    "PUB-014",
    "/methodology/rules/synthetic-record",
    "/methodology/rules/synthetic-record",
  ],
  ["PUB-018", "/corrections", "/corrections"],
  [
    "PUB-019",
    "/corrections/80000000-0000-4000-8000-000000000001",
    "/corrections/80000000-0000-4000-8000-000000000001",
  ],
] as const) {
  test(`[R6D-PUBLIC-SEO] ${screenId} shares exact description and canonical metadata`, async ({
    page,
  }) => {
    await page.goto(`${publicBase}${path}`, { waitUntil: "networkidle" });
    const description = await page
      .locator('meta[name="description"]')
      .getAttribute("content");
    expect(description?.trim().length).toBeGreaterThan(0);
    await expect(
      page.locator('meta[property="og:description"]'),
    ).toHaveAttribute("content", description ?? "");
    await expect(page.locator('link[rel="canonical"]')).toHaveAttribute(
      "href",
      `${publicBase}${canonicalPath}`,
    );
    await expect(page.locator('meta[name="robots"]')).toHaveAttribute(
      "content",
      "index,follow",
    );
  });
}

test("[R6D-PUBLIC-SEO] Awaiting-query search metadata is neutral and canonical", async ({
  page,
}) => {
  await page.goto(`${publicBase}/search`, { waitUntil: "networkidle" });
  await expect(
    page.getByText("검색어 입력 대기", { exact: true }),
  ).toBeVisible();
  const description = await page
    .locator('meta[name="description"]')
    .getAttribute("content");
  expect(description?.trim().length).toBeGreaterThan(0);
  expect(description).not.toMatch(/오류|실패|준비할 수 없습니다|불러오지 못/u);
  await expect(page.locator('meta[property="og:description"]')).toHaveAttribute(
    "content",
    description ?? "",
  );
  await expect(page.locator('link[rel="canonical"]')).toHaveAttribute(
    "href",
    `${publicBase}/search`,
  );
});

test("[R6D-LEGAL-001] Legal documents keep their canonical section order", async ({
  page,
}) => {
  for (const [path, sectionIds] of [
    [
      "/privacy",
      [
        "controller",
        "categories",
        "purposes",
        "retention",
        "processors",
        "rights",
        "security",
        "history",
      ],
    ],
    [
      "/terms",
      ["service", "content", "data", "prohibited", "liability", "changes"],
    ],
  ] as const) {
    await page.goto(`${publicBase}${path}`, { waitUntil: "networkidle" });
    const sections = page.locator(
      "main#main-content section[data-component]:not(#page-actions)",
    );
    expect(
      await sections.evaluateAll((items) => items.map(({ id }) => id)),
    ).toEqual(sectionIds);
    await expect(sections.locator(".legal-body")).toHaveCount(
      sectionIds.length,
    );
    await expect(sections.locator('[role="alert"]')).toHaveCount(0);
  }
});

test("[R6D-LEGAL-002] Terms keep all three redistribution obligations", async ({
  page,
}) => {
  await page.goto(`${publicBase}/terms`, { waitUntil: "networkidle" });
  const dataTerms = page.locator("main#main-content section#data .legal-body");
  for (const obligation of [
    "재배포물에 원 자료의 공개·검토·정정 상태를 유지해야 합니다.",
    '재배포물에 "이상 징후 기록이며 위법·부패의 확정이 아님" 고지를 유지해야 합니다.',
    "정정·철회가 게시되면 재배포물에도 해당 표시를 반영하거나 최신 revision으로 연결해야 합니다.",
  ] as const) {
    await expect(dataTerms).toContainText(obligation);
  }
});

test("[R6D-LEGAL-003] Privacy renders only approved retention schedules", async ({
  page,
}) => {
  await page.goto(`${publicBase}/privacy`, { waitUntil: "networkidle" });
  await expect(page.locator("#retention [role=alert]")).toHaveCount(0);
  const table = page.locator("#retention .retention-table-scroll table");
  await expect(table).toHaveCount(1);
  await expect(table.locator("thead th")).toHaveCount(9);
  expect(await table.locator("tbody tr").count()).toBeGreaterThan(0);
  const text = await page.locator("body").innerText();
  expect(text).not.toMatch(
    /scheduleDigest|AGENCY_MASTER|SUPPLIER_MASTER|PRESERVE_[A-Z_]+|\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/u,
  );
});

test("[R6D-PRIVACY-BFF-001] Privacy rejects URL token side doors without reflecting the secret", async ({
  page,
}) => {
  const token = `forbidden-${"s".repeat(48)}`;
  await page.goto(`${publicBase}/privacy?token=${encodeURIComponent(token)}`, {
    waitUntil: "networkidle",
  });
  expect(page.url()).toBe(
    `${publicBase}/privacy?notice=${encodeURIComponent("보안 링크를 사용할 수 없습니다.")}`,
  );
  expect(await page.locator("html").innerText()).not.toContain(token);
  expect(await page.content()).not.toContain(token);
});
