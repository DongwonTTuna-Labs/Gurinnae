import { expect, test } from "@playwright/test";
import { routeCatalog } from "./support/route-catalog";

test("[PUB-017] official source action opens the validated external URL", async ({
  page,
  request,
}) => {
  await request.post("http://127.0.0.1:29100/_test/reset");
  const contract = routeCatalog().find(
    ({ screenId }) => screenId === "PUB-017",
  );
  expect(contract, "PUB-017 route contract").toBeDefined();
  if (!contract) return;
  await page.goto(contract.url, { waitUntil: "networkidle" });
  const action = page.locator('[data-action-id="view-official"]');
  await expect(action).toHaveCount(1);
  await expect(action).toHaveAttribute("href", "https://www.data.go.kr/");
  await expect(action).toHaveAttribute("target", "_blank");
  await expect(action).toHaveAttribute("rel", "noopener noreferrer");
});
