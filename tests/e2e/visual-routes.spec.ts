import { expect, test } from "@playwright/test";
import { routeCatalog } from "./support/route-catalog";

const viewports = [
  { name: "wide", width: 1440, height: 900 },
  { name: "medium", width: 900, height: 900 },
  { name: "compact", width: 360, height: 800 },
] as const;

for (const contract of routeCatalog())
  for (const viewport of viewports) {
    test(`${contract.screenId} ${viewport.name} visual`, async ({ page }) => {
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });
      await page.goto(contract.url, { waitUntil: "networkidle" });
      await page.evaluate(() => document.fonts.ready);
      await expect(page).toHaveScreenshot(
        `${contract.screenId.toLowerCase()}-${viewport.name}.png`,
        {
          fullPage: true,
          animations: "disabled",
          caret: "hide",
        },
      );
    });
  }
