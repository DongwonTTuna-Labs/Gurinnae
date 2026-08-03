import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { expect, test } from "@playwright/test";
import { routeCatalog } from "./support/route-catalog";

const traceRoot = resolve("implementation-evidence/runtime-traces");
mkdirSync(traceRoot, { recursive: true });

for (const contract of routeCatalog()) {
  test(`${contract.screenId} runtime trace`, async ({ page, request }) => {
    const ssr = await request.get(contract.url);
    expect(ssr.status(), `${contract.screenId} SSR status`).toBe(200);
    const html = await ssr.text();
    expect(html).toContain(`data-screen-id="${contract.screenId}"`);

    // Some routes intentionally keep a long-lived polling connection.  A
    // runtime trace must remain bounded and observe the committed DOM rather
    // than waiting for an impossible network-idle point.
    await page.goto(contract.url, {
      waitUntil: "domcontentloaded",
      timeout: 15_000,
    });
    await page.waitForSelector(`main[data-screen-id="${contract.screenId}"]`, {
      timeout: 5_000,
    });
    const observation = await page.evaluate(() => ({
      screenId: document.querySelector("main")?.getAttribute("data-screen-id"),
      headingCount: document.querySelectorAll("h1").length,
      sections: [
        ...document.querySelectorAll(
          "main section[data-component]:not(#page-actions)",
        ),
      ].map((section) => ({
        id: section.id,
        component: section.getAttribute("data-component"),
        projectionState: section.getAttribute("data-projection-state"),
      })),
      state: document
        .querySelector("main[data-state]")
        ?.getAttribute("data-state"),
      errorSummary: Boolean(document.querySelector('[role="alert"]')),
      focusTargets: document.querySelectorAll("[data-focus-target]").length,
      viewport: { width: window.innerWidth, height: window.innerHeight },
    }));
    expect(observation.screenId).toBe(contract.screenId);
    expect(observation.headingCount).toBe(1);
    for (const expected of contract.sections) {
      expect(observation.sections).toContainEqual(
        expect.objectContaining({
          id: expected.id,
          component: expected.component,
        }),
      );
    }

    writeFileSync(
      resolve(traceRoot, `${contract.screenId.toLowerCase()}.json`),
      `${JSON.stringify(
        {
          schemaVersion: "gurine.screen-runtime-trace.v1",
          screenId: contract.screenId,
          route: contract.route,
          url: contract.url,
          observedAt: new Date().toISOString(),
          ssrStatus: ssr.status(),
          observation,
        },
        null,
        2,
      )}\n`,
      "utf8",
    );
  });
}

test("authenticated CAS analysis uses authority API envelope through projection", async ({
  page,
  request,
}) => {
  const review = "http://127.0.0.1:29102";
  const caseId = "80000000-0000-4000-8000-000000000001";
  const runId = caseId;
  await request.post("http://127.0.0.1:29100/_test/reset");
  await page.goto(
    `${review}/auth/login?returnTo=${encodeURIComponent(`/internal/cases/${caseId}/agent-runs`)}`,
    { waitUntil: "domcontentloaded" },
  );
  await expect(page).toHaveURL(`${review}/internal/cases/${caseId}/agent-runs`);
  await expect(page.locator("main[data-screen-id='CAS-010']")).toBeVisible();
  await expect(page.getByTestId("runs-visualizations")).toBeVisible();
  await expect(
    page.getByText("현재 케이스에 연결된 실행만 집계했습니다."),
  ).toBeVisible();
  await expect(page.getByTestId("runs-run-count-table")).toBeVisible();

  const cas010Positive = await page.evaluate(() => ({
    authenticated: true,
    screenId: document.querySelector("main")?.getAttribute("data-screen-id"),
    errorSummary: Boolean(document.querySelector('[role="alert"]')),
    sections: [
      ...document.querySelectorAll("main section[data-component]"),
    ].map((section) => ({
      id: section.id,
      projectionState: section.getAttribute("data-projection-state"),
    })),
    visualizations: document.querySelectorAll(
      "[data-testid='runs-visualizations'] table",
    ).length,
    accessibleTableRows: document.querySelectorAll(
      "[data-testid='runs-visualizations'] tbody tr",
    ).length,
    viewport: { width: window.innerWidth, height: window.innerHeight },
  }));
  writeFileSync(
    resolve(traceRoot, "cas-010-authenticated.json"),
    `${JSON.stringify({ schemaVersion: "gurine.screen-runtime-trace.v1", screenId: "CAS-010", route: `/internal/cases/${caseId}/agent-runs`, observedAt: new Date().toISOString(), observation: cas010Positive }, null, 2)}\n`,
    "utf8",
  );

  await page.goto(`${review}/internal/cases/${caseId}/agent-runs/${runId}`, {
    waitUntil: "domcontentloaded",
  });
  await expect(page.locator("main[data-screen-id='CAS-011']")).toBeVisible();
  await expect(page.getByTestId("inputs-provenance")).toBeVisible();
  await expect(page.getByText("문서 분석 Agent").first()).toBeVisible();
  await expect(page.getByTestId("output-visualizations")).toBeVisible();
  await expect(page.getByTestId("output-run-count-table")).toBeVisible();

  const cas011Positive = await page.evaluate(() => ({
    authenticated: true,
    screenId: document.querySelector("main")?.getAttribute("data-screen-id"),
    errorSummary: Boolean(document.querySelector('[role="alert"]')),
    sections: [
      ...document.querySelectorAll("main section[data-component]"),
    ].map((section) => ({
      id: section.id,
      projectionState: section.getAttribute("data-projection-state"),
    })),
    visualizations: document.querySelectorAll(
      "[data-testid='output-visualizations'] table",
    ).length,
    accessibleProvenanceRows: document.querySelectorAll(
      "[data-testid='inputs-provenance'] tbody tr",
    ).length,
    viewport: { width: window.innerWidth, height: window.innerHeight },
  }));
  writeFileSync(
    resolve(traceRoot, "cas-011-authenticated.json"),
    `${JSON.stringify({ schemaVersion: "gurine.screen-runtime-trace.v1", screenId: "CAS-011", route: `/internal/cases/${caseId}/agent-runs/${runId}`, observedAt: new Date().toISOString(), observation: cas011Positive }, null, 2)}\n`,
    "utf8",
  );
});
