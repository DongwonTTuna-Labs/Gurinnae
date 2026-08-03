import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { expect, test } from "@playwright/test";

const publicBase = "http://127.0.0.1:29101";
const mockBase = "http://127.0.0.1:29100";
const reportPathPattern =
  /^\/downloads\/transparency-reports\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\?format=(JSON|CSV)$/u;
const independenceNotice = "후원은 접근권이 아니며 조사 대상 면제가 아닙니다";

test.beforeEach(async ({ request }) => {
  await request.post(`${mockBase}/_test/reset`);
});

test("[PUB-023-001] first approved report binds one reportId to the primary action and both downloads", async ({
  page,
  request,
}) => {
  await page.goto(`${publicBase}/about/funding`, {
    waitUntil: "networkidle",
  });

  await expect(page.locator("main#main-content")).toHaveAttribute(
    "data-screen-id",
    "PUB-023",
  );
  await expect(page.locator("#principles")).toContainText(independenceNotice);

  const reports = page.locator("#reports");
  const jsonLink = reports
    .getByRole("link", { name: "JSON", exact: true })
    .first();
  const csvLink = reports
    .getByRole("link", { name: "CSV", exact: true })
    .first();
  const json = requiredReportHref(await jsonLink.getAttribute("href"), "JSON");
  const csv = requiredReportHref(await csvLink.getAttribute("href"), "CSV");
  expect(json.reportId).toBe(csv.reportId);

  const primary = page.locator('a[data-action-id="download-report"]');
  await expect(primary).toHaveCount(1);
  await expect(primary).toHaveAttribute("href", json.href);

  for (const download of [
    { format: "JSON", link: jsonLink, href: json.href },
    { format: "CSV", link: csvLink, href: csv.href },
  ] as const) {
    const extension = download.format.toLowerCase();
    const filename = `gurine-funding-transparency-${json.reportId}.${extension}`;
    const response = await request.get(`${publicBase}${download.href}`);
    const bytes = await response.body();
    const digest = createHash("sha256").update(bytes).digest("hex");

    expect(response.status()).toBe(200);
    expect(response.headers()["cache-control"]).toBe("no-store");
    expect(response.headers()["content-length"]).toBe(String(bytes.byteLength));
    expect(response.headers()["x-content-sha256"]).toBe(digest);
    expect(response.headers()["x-content-type-options"]).toBe("nosniff");
    expect(response.headers()["content-disposition"]).toContain(
      `filename="${filename}"`,
    );
    expect(response.headers()["content-type"]).toContain(
      download.format === "JSON" ? "application/json" : "text/csv",
    );
    expect(bytes.toString("utf8")).not.toMatch(
      /billingKey|providerPaymentId|paymentAuthorizationToken|donorId/u,
    );

    const downloadEvent = page.waitForEvent("download");
    await download.link.click();
    const browserDownload = await downloadEvent;
    expect(browserDownload.suggestedFilename()).toBe(filename);
    const downloadedPath = await browserDownload.path();
    if (!downloadedPath) throw new Error(`${download.format} 파일이 없습니다.`);
    expect(await readFile(downloadedPath)).toEqual(bytes);
  }
});

test("[PUB-023-002] invalid format and unknown report fail closed without artifact headers", async ({
  request,
}) => {
  const unknownId = "77777777-7777-4777-8777-777777777777";
  for (const target of [
    "/downloads/transparency-reports/not-a-uuid?format=JSON",
    `/downloads/transparency-reports/${unknownId}?format=JSON`,
    `/downloads/transparency-reports/${unknownId}?format=PDF`,
  ]) {
    const response = await request.get(`${publicBase}${target}`);
    expect([400, 404]).toContain(response.status());
    expect(await response.text()).toBe("투명성 보고서를 내려받지 못했습니다.");
    expect(response.headers()["cache-control"]).toBe("no-store");
    expect(response.headers()["content-disposition"]).toBeUndefined();
    expect(response.headers()["x-content-sha256"]).toBeUndefined();
  }
});

test("[PUB-023-003] unavailable report list leaves approved content visible in partial state", async ({
  page,
}) => {
  await page.goto(
    `${publicBase}/about/funding?__testFixture=FUNDING_LIST_UNAVAILABLE`,
    { waitUntil: "networkidle" },
  );

  await expect(page.locator('p[data-state="partial"]')).toHaveText(
    "현재 상태: 일부만 확인됨",
  );
  await expect(page.locator("#principles")).toContainText(independenceNotice);
  await expect(page.locator("#reports")).toContainText("공개 자료 없음");
  await expect(page.locator("#reports")).toContainText(
    "다운로드 가능한 승인 보고서가 없습니다.",
  );
  await expect(page.locator('#reports a[download=""]')).toHaveCount(0);
  await expect(page.locator('a[data-action-id="download-report"]')).toHaveCount(
    0,
  );
  await expect(
    page.locator('div.download-unavailable[data-action-id="download-report"]'),
  ).toHaveCount(1);
});

function requiredReportHref(
  value: string | null,
  expectedFormat: "JSON" | "CSV",
): { href: string; reportId: string } {
  if (!value) throw new Error(`${expectedFormat} 보고서 주소가 없습니다.`);
  const match = value.match(reportPathPattern);
  if (!match || match[2] !== expectedFormat || !match[1]) {
    throw new Error(`${expectedFormat} 보고서 주소가 계약과 다릅니다.`);
  }
  return { href: value, reportId: match[1] };
}
