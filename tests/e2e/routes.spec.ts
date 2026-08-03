import { expect, test } from "@playwright/test";
import { forbiddenRawEnumValues } from "../../packages/ui/src/enum-presentation";
import { routeCatalog } from "./support/route-catalog";

const forbiddenInternalTerms = [
  "투영값",
  "권위",
  "허용 목록",
  "출처 지문",
  "화면 작업",
  "여정 ID",
] as const;

const isoDateTimePattern =
  /\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,9})?)?(?:Z|[+-]\d{2}:\d{2})?\b/u;
const fullUuidPattern =
  /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/iu;
const emptyContainerPattern =
  /(^|[^\p{L}\p{N}_])(?:\{\}|\[\])(?=$|[^\p{L}\p{N}_])/u;
const journeyIdPattern = /\bJ-\d{2,}\b/u;

for (const contract of routeCatalog()) {
  test(`${contract.screenId} ${contract.route} SSR, accessibility, responsive`, async ({
    page,
    request,
  }) => {
    const pageErrors: string[] = [];
    const consoleErrors: string[] = [];
    page.on("pageerror", (error) => pageErrors.push(error.message));
    page.on("console", (message) => {
      if (message.type() === "error") consoleErrors.push(message.text());
    });

    const ssr = await request.get(contract.url);
    expect(ssr.status(), `${contract.screenId} SSR status`).toBe(200);
    const html = await ssr.text();
    expect(html).toContain(`data-screen-id="${contract.screenId}"`);
    expect(html).toContain("<h1");
    expect(html).not.toContain("MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE=");

    await page.goto(contract.url, { waitUntil: "networkidle" });
    await expect(page.locator("main")).toHaveAttribute(
      "data-screen-id",
      contract.screenId,
    );
    await expect(page.locator("h1")).toHaveCount(1);
    await expect(
      page.locator('a.local-action[href*="?action="]'),
      `${contract.screenId} has no inert local action links`,
    ).toHaveCount(0);
    const sections = await page
      .locator("main section[data-component]:not(#page-actions)")
      .evaluateAll((elements) =>
        elements.map((element) => ({
          id: element.id,
          component: element.getAttribute("data-component") ?? "",
        })),
      );
    expect(sections, `${contract.screenId} manifest section sequence`).toEqual(
      contract.sections,
    );
    await auditDocument(page);
    await auditRenderedText(page, contract.screenId);

    await page.setViewportSize({ width: 360, height: 800 });
    await expect(page.locator("h1")).toBeVisible();
    const compactSearch = page.locator(
      'header.public-header a.icon-button[href="/search"]',
    );
    if ((await compactSearch.count()) === 1) {
      const renderedLineCount = await compactSearch.evaluate((element) => {
        const range = document.createRange();
        range.selectNodeContents(element);
        return new Set(
          [...range.getClientRects()].map((rect) => Math.round(rect.top)),
        ).size;
      });
      expect(
        renderedLineCount,
        `${contract.screenId} compact search label line count`,
      ).toBe(1);
    }
    const coverageStats = page.locator(".coverage-stats");
    if ((await coverageStats.count()) > 0) {
      const rowCount = await coverageStats.first().evaluate((element) => {
        return new Set(
          [...element.children].map((child) =>
            Math.round(child.getBoundingClientRect().top),
          ),
        ).size;
      });
      expect(
        rowCount,
        `${contract.screenId} compact coverage stat row count`,
      ).toBe(1);
    }
    const overflow = await page.evaluate(
      () =>
        document.documentElement.scrollWidth -
        document.documentElement.clientWidth,
    );
    expect(
      overflow,
      `${contract.screenId} compact body overflow`,
    ).toBeLessThanOrEqual(1);
    await expect(
      page.locator("main section[data-component]").first(),
    ).toBeVisible();
    expect(pageErrors, `${contract.screenId} page errors`).toEqual([]);
    expect(consoleErrors, `${contract.screenId} console errors`).toEqual([]);
  });
}

test("local download action produces a file", async ({ page }) => {
  await page.goto("http://127.0.0.1:29101/contracts", {
    waitUntil: "networkidle",
  });
  const download = page.waitForEvent("download");
  await page.locator('[data-action-id="download"]').click();
  const artifact = await download;
  expect(artifact.suggestedFilename()).toBe("pub-011-download.json");
});

test("OpenAPI download is proxied as an attachment", async ({ request }) => {
  const response = await request.get("http://127.0.0.1:29101/api/openapi.json");
  expect(response.status()).toBe(200);
  expect(response.headers()["content-disposition"]).toBe(
    'attachment; filename="gurine-public-api.openapi.json"',
  );
  expect(response.headers()["content-type"]).toContain("application/json");
});

test("public ledger downloads retain the current filters and required format", async ({
  page,
}) => {
  const agencyId = "11000000-0000-4000-8000-000000000001";
  const supplierId = "22000000-0000-4000-8000-000000000001";
  const cases = [
    {
      pageUrl: `/search?q=%EA%B3%84%EC%95%BD&types=CASE&types=AGENCY&publicationState=PUBLISHED_ANOMALY&agencyId=${agencyId}&dateFrom=2026-01-01&sort=relevance&cursor=excluded`,
      pathname: "/downloads/search",
      filters: [
        ["q", "계약"],
        ["types", "CASE"],
        ["types", "AGENCY"],
        ["publicationState", "PUBLISHED_ANOMALY"],
        ["agencyId", agencyId],
        ["dateFrom", "2026-01-01"],
        ["sort", "relevance"],
      ],
    },
    {
      pageUrl: `/cases?publicationState=PUBLISHED_ANOMALY&agencyId=${agencyId}&supplierId=${supplierId}&ruleId=rule-1&sidoCode=11&sigunguCode=11110&publishedFrom=2026-01-01&publishedTo=2026-06-30&hasResponse=true&hasCorrection=false&sort=title_asc&limit=10&cursor=excluded`,
      pathname: "/downloads/cases",
      filters: [
        ["publicationState", "PUBLISHED_ANOMALY"],
        ["agencyId", agencyId],
        ["supplierId", supplierId],
        ["ruleId", "rule-1"],
        ["sidoCode", "11"],
        ["sigunguCode", "11110"],
        ["publishedFrom", "2026-01-01"],
        ["publishedTo", "2026-06-30"],
        ["hasResponse", "true"],
        ["hasCorrection", "false"],
        ["sort", "title_asc"],
      ],
    },
  ] as const;

  for (const contract of cases) {
    await page.goto(`http://127.0.0.1:29101${contract.pageUrl}`, {
      waitUntil: "networkidle",
    });
    for (const [actionId, format] of [
      ["download-csv", "CSV"],
      ["download-jsonl", "JSONL"],
    ] as const) {
      const action = page.locator(`a[data-action-id="${actionId}"]`);
      await expect(action).toBeVisible();
      const href = await action.getAttribute("href");
      if (!href) throw new Error(`${actionId} 내려받기 주소가 없습니다.`);
      const destination = new URL(href, "http://127.0.0.1:29101");
      expect(destination.pathname).toBe(contract.pathname);
      expect([...destination.searchParams.entries()]).toEqual([
        ...contract.filters,
        ["format", format],
      ]);
      expect(destination.searchParams.has("cursor")).toBe(false);
      expect(destination.searchParams.has("limit")).toBe(false);
    }
  }
});

test("home renders recent public records and a copy-complete mission", async ({
  page,
}) => {
  await page.goto("http://127.0.0.1:29101/", { waitUntil: "networkidle" });

  const mission = page.locator(
    'section[data-testid="pub_001__section__mission"]',
  );
  await expect(mission).toContainText(
    "이상 징후와 위법·비리 확정의 구분 원칙.",
  );
  await expect(mission.locator('[data-testid="empty-state"]')).toHaveCount(0);
  await expect(mission).not.toContainText("확인 가능한 자료가 없습니다.");

  const recent = page.locator(
    'section[data-testid="pub_001__section__recent"]',
  );
  await expect(recent.locator("tbody tr")).toHaveCount(8);
  await expect(recent.locator("tbody tr").first()).toContainText("계약");
  await expect(recent.locator('[data-action-id="open-case"]')).toHaveCount(0);
  await expect(
    recent.locator(
      '.public-section-status-notice > .public-status-notice[data-notice-kind="NON_CONCLUSION"]',
    ),
  ).toHaveCount(0);
  await expect(recent.locator("tbody .public-status-notice")).toHaveCount(0);
  await expect(page.locator(".home-safety")).toHaveText(
    "자동 부패 판정기가 아닙니다 — 가격 차이나 반복 계약은 조사 신호일 뿐 위법·비리를 의미하지 않습니다.",
  );

  const corrections = page.locator(
    'section[data-testid="pub_001__section__corrections"]',
  );
  expect(
    await corrections.locator(".projection-record").count(),
  ).toBeGreaterThanOrEqual(3);
  await expect(corrections).toContainText(
    "종료일을 원문 계약서 기준으로 바로잡았습니다.",
  );
  await expect(corrections).toContainText("2026.07.29");
  await expect(
    corrections.locator(
      '.public-section-status-notice > .public-status-notice[data-notice-kind="NON_CONCLUSION"]',
    ),
  ).toContainText("이상 징후 기록이며 위법·부패의 확정이 아님");
  await expect(corrections.locator("li .public-status-notice")).toHaveCount(0);
  await expect(
    page.locator(
      'main#main-content .public-status-notice[data-notice-kind="NON_CONCLUSION"]',
    ),
  ).toHaveCount(1);
  await expect(corrections.locator('[data-testid="empty-state"]')).toHaveCount(
    0,
  );

  const coverage = page.locator(
    'section[data-testid="pub_001__section__coverage"]',
  );
  await expect(coverage).toContainText("수집 출처");
  await expect(coverage).toContainText("8개");
  await expect(coverage).not.toContainText("확인된 항목 0개");

  const summaryStyle = await recent
    .locator(".title-summary span")
    .first()
    .evaluate((element) => ({
      overflow: getComputedStyle(element).overflow,
      textOverflow: getComputedStyle(element).textOverflow,
      whiteSpace: getComputedStyle(element).whiteSpace,
    }));
  expect(summaryStyle).toEqual({
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  });
});

test("case detail renders its validated lead and three-way evidence split", async ({
  page,
}) => {
  await page.goto("http://127.0.0.1:29101/cases/synthetic-record", {
    waitUntil: "networkidle",
  });

  await expect(page.locator(".error-summary")).toHaveCount(0);
  await expect(page.locator("h1")).toHaveText("공개 사례 테스트");
  await expect(page.locator(".public-case-meta")).toContainText(
    "가상해안시 도시정책국",
  );
  await expect(page.locator(".public-case-meta")).toContainText(
    "가상 해안도시 통합계약",
  );
  await expect(page.locator(".public-case-stats")).toContainText(
    "₩1,250,000,000",
  );
  for (const expected of ["확인1", "미확인1", "소명1"] as const) {
    await expect(page.locator(".public-case-stats")).toContainText(expected);
  }
  for (const sectionId of ["known", "unknown", "response"] as const) {
    const section = page.locator(`#${sectionId}`);
    await expect(section).not.toContainText("자료 없음");
    await expect(section).not.toHaveAttribute("data-projection-state", "ERROR");
  }
});

test("search downloads stay absent before a query exists", async ({ page }) => {
  await page.goto("http://127.0.0.1:29101/search", {
    waitUntil: "networkidle",
  });
  for (const actionId of ["download-csv", "download-jsonl"] as const) {
    await expect(page.locator(`a[data-action-id="${actionId}"]`)).toHaveCount(
      0,
    );
    await expect(
      page.locator(`.download-unavailable[data-action-id="${actionId}"]`),
    ).toHaveCount(0);
  }
  await expect(
    page.getByText("현재 다운로드를 준비할 수 없습니다."),
  ).toHaveCount(0);
});

async function auditDocument(
  page: import("@playwright/test").Page,
): Promise<void> {
  const audit = await page.evaluate(() => {
    const ids = [...document.querySelectorAll<HTMLElement>("[id]")].map(
      (element) => element.id,
    );
    const duplicateIds = ids.filter((id, index) => ids.indexOf(id) !== index);
    const headingLevels = [
      ...document.querySelectorAll("h1,h2,h3,h4,h5,h6"),
    ].map((heading) => Number(heading.tagName.slice(1)));
    const headingJump = headingLevels.some(
      (level, index) =>
        index > 0 && level - (headingLevels[index - 1] ?? 1) > 1,
    );
    const unnamed = [
      ...document.querySelectorAll<HTMLElement>(
        "button,input,select,textarea,a[href]",
      ),
    ].filter((element) => {
      if (element instanceof HTMLInputElement && element.type === "hidden")
        return false;
      const labelled =
        element.getAttribute("aria-label") ||
        element.getAttribute("aria-labelledby");
      const text = element.textContent?.trim();
      const label = element.id
        ? document.querySelector(`label[for="${CSS.escape(element.id)}"]`)
        : element.closest("label");
      return !labelled && !text && !label;
    }).length;
    const missingAlt = document.querySelectorAll("img:not([alt])").length;
    return {
      duplicateIds,
      headingJump,
      unnamed,
      missingAlt,
      lang: document.documentElement.lang,
    };
  });
  expect(audit.duplicateIds).toEqual([]);
  expect(audit.headingJump).toBe(false);
  expect(audit.unnamed).toBe(0);
  expect(audit.missingAlt).toBe(0);
  expect(audit.lang).toBe("ko");
}

type RenderedTextSample = {
  context: string;
  value: string;
};

async function auditRenderedText(
  page: import("@playwright/test").Page,
  screenId: string,
): Promise<void> {
  const samples = await page.locator("main").evaluate((main) => {
    const visibleText = (main as HTMLElement).innerText
      .split("\n")
      .map((line) => line.replace(/\s+/gu, " ").trim())
      .filter(Boolean)
      .map((value, index) => ({
        context: `main visible text line ${index + 1}`,
        value,
      }));
    const controls = [
      ...main.querySelectorAll<HTMLInputElement | HTMLTextAreaElement>(
        'input:not([type="hidden"]), textarea',
      ),
    ].filter((element) =>
      element.checkVisibility({
        checkOpacity: true,
        checkVisibilityCSS: true,
      }),
    );
    const formText = controls.flatMap((element, index) => {
      const values: RenderedTextSample[] = [];
      if (element.placeholder.trim()) {
        values.push({
          context: `visible form control ${index + 1} placeholder`,
          value: element.placeholder.trim(),
        });
      }
      if (
        element instanceof HTMLTextAreaElement &&
        element.defaultValue.trim()
      ) {
        values.push({
          context: `visible textarea ${index + 1} initial value`,
          value: element.defaultValue.trim(),
        });
      }
      return values;
    });
    return [...visibleText, ...formText];
  });

  const violations = renderedTextViolations(samples).map(
    (violation) => `${screenId} ${violation}`,
  );
  expect(
    violations,
    `${screenId} visible user-surface render smell audit`,
  ).toEqual([]);
}

function renderedTextViolations(
  samples: readonly RenderedTextSample[],
): string[] {
  const violations: string[] = [];
  for (const sample of samples) {
    for (const rawEnum of forbiddenRawEnumValues) {
      if (containsExactToken(sample.value, rawEnum)) {
        violations.push(
          `${sample.context}: raw enum ${rawEnum} in ${excerpt(sample.value, rawEnum)}`,
        );
      }
    }
    for (const term of forbiddenInternalTerms) {
      if (sample.value.includes(term)) {
        violations.push(
          `${sample.context}: internal term ${term} in ${excerpt(sample.value, term)}`,
        );
      }
    }
    const journeyId = sample.value.match(journeyIdPattern)?.[0];
    if (journeyId) {
      violations.push(
        `${sample.context}: journey ID ${journeyId} in ${excerpt(sample.value, journeyId)}`,
      );
    }
    const isoDateTime = sample.value.match(isoDateTimePattern)?.[0];
    if (isoDateTime) {
      violations.push(
        `${sample.context}: ISO datetime ${isoDateTime} in ${excerpt(sample.value, isoDateTime)}`,
      );
    }
    const fullUuid = sample.value.match(fullUuidPattern)?.[0];
    if (fullUuid) {
      violations.push(
        `${sample.context}: full UUID ${fullUuid} in ${excerpt(sample.value, fullUuid)}`,
      );
    }
    const emptyContainer = sample.value.match(emptyContainerPattern)?.[0];
    if (emptyContainer) {
      const token = emptyContainer.includes("{}") ? "{}" : "[]";
      violations.push(
        `${sample.context}: empty container ${token} in ${excerpt(sample.value, token)}`,
      );
    }
  }
  return violations;
}

function containsExactToken(value: string, token: string): boolean {
  const escaped = token.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  return new RegExp(`(^|[^A-Za-z0-9_])${escaped}(?=$|[^A-Za-z0-9_])`, "u").test(
    value,
  );
}

function excerpt(value: string, finding: string): string {
  const findingIndex = Math.max(value.indexOf(finding), 0);
  const start = Math.max(findingIndex - 48, 0);
  const end = Math.min(findingIndex + finding.length + 48, value.length);
  const prefix = start > 0 ? "…" : "";
  const suffix = end < value.length ? "…" : "";
  return JSON.stringify(`${prefix}${value.slice(start, end)}${suffix}`);
}
