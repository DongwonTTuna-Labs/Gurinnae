import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { expect, test } from "@playwright/test";
import "./routes-screen-contracts";

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

test("funding transparency downloads verified JSON and CSV files", async ({
  page,
  request,
}) => {
  await request.post("http://127.0.0.1:29100/_test/reset");
  await page.goto("http://127.0.0.1:29101/about/funding", {
    waitUntil: "networkidle",
  });

  for (const format of ["JSON", "CSV"] as const) {
    const link = page
      .locator('#reports a[download=""]')
      .filter({ hasText: format })
      .first();
    const href = await link.getAttribute("href");
    if (!href) throw new Error(`${format} 투명성 보고서 주소가 없습니다.`);

    const response = await request.get(`http://127.0.0.1:29101${href}`);
    const expectedBytes = await response.body();
    const expectedDigest = createHash("sha256")
      .update(expectedBytes)
      .digest("hex");
    expect(response.status()).toBe(200);
    expect(response.headers()["cache-control"]).toBe("no-store");
    expect(response.headers()["x-content-type-options"]).toBe("nosniff");
    expect(response.headers()["x-content-sha256"]).toBe(expectedDigest);
    expect(expectedBytes.toString("utf8")).not.toMatch(
      /billingKey|providerPaymentId|paymentAuthorizationToken|donorId/u,
    );

    const downloadEvent = page.waitForEvent("download");
    await link.click();
    const download = await downloadEvent;
    expect(download.suggestedFilename()).toMatch(
      new RegExp(
        `^gurine-funding-transparency-[0-9a-f-]+\\.${format.toLowerCase()}$`,
        "u",
      ),
    );
    const downloadedPath = await download.path();
    if (!downloadedPath) throw new Error(`${format} 다운로드 파일이 없습니다.`);
    expect(await readFile(downloadedPath)).toEqual(expectedBytes);
  }
});

test("donation request stays test-only and announces a queued receipt", async ({
  page,
  request,
}) => {
  await request.post("http://127.0.0.1:29100/_test/reset");
  await page.goto("http://127.0.0.1:29101/donate", {
    waitUntil: "networkidle",
  });

  await expect(page.locator("main")).toHaveAttribute(
    "data-screen-id",
    "PUB-035",
  );
  await expect(
    page.locator("#independence .independence-ledger strong"),
  ).toHaveText("후원은 접근권이 아니며 조사 대상 면제가 아닙니다");

  const tier = page.locator('input[name="tierId"]').first();
  await tier.focus();
  await page.keyboard.press("Space");
  await expect(tier).toBeChecked();

  const cadence = page.locator('input[name="cadence"]').first();
  await cadence.focus();
  await page.keyboard.press("Space");
  await expect(cadence).toBeChecked();

  const provider = page.locator('select[name="provider"]');
  await provider.focus();
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("Enter");
  await expect(provider).toHaveValue("TOSS_PAYMENTS");

  const consent = page.locator('input[name="consent"]');
  await consent.focus();
  await page.keyboard.press("Space");
  await expect(consent).toBeChecked();

  const submit = page.locator(
    '[data-testid="pub_035__action__queue_donation"] button[type="submit"]',
  );
  await submit.focus();
  await expect(submit).toBeFocused();

  const offerDigest = page.locator('input[name="offerDigest"]');
  const currentOfferDigest = await offerDigest.inputValue();
  await offerDigest.evaluate((element) => {
    (element as HTMLInputElement).value = "0".repeat(64);
  });
  await page.keyboard.press("Enter");

  const errorSummary = page.locator("#donation-form-error-summary");
  await expect(errorSummary).toContainText("후원 금액 구성이 변경되었습니다.");
  await expect(tier).toBeChecked();
  await expect(cadence).toBeChecked();
  await expect(provider).toHaveValue("TOSS_PAYMENTS");
  await expect(consent).toBeChecked();
  await expect(provider).toHaveAttribute(
    "aria-describedby",
    /donation-form-error-summary/u,
  );
  await expect(offerDigest).toHaveValue(currentOfferDigest);

  await submit.focus();
  await expect(submit).toBeFocused();
  await page.keyboard.press("Enter");

  const receiptHeading = page.getByRole("heading", {
    name: "후원 요청 접수",
  });
  await expect(receiptHeading).toBeVisible();
  await expect(receiptHeading).toBeFocused();
  await expect(page.locator(".receipt-ledger")).toContainText("접수 대기");
  await expect(page.locator(".receipt-notice")).toContainText(
    "접수 대기는 결제 성공이 아니며",
  );

  const bodyText = await page.locator("body").innerText();
  expect(bodyText).not.toContain("TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY");
  expect(bodyText).not.toContain("paymentAuthorizationToken");
  expect(bodyText).not.toMatch(/결제 (?:완료|성공했습니다)/u);
});
