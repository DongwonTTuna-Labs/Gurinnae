import { randomUUID } from "node:crypto";
import { expect, test } from "@playwright/test";
import { sha256, state } from "./submission-routing.shared";

const publicWeb = "http://127.0.0.1:29101";

const contracts = [
  {
    screenId: "PUB-028",
    exchangePath: "/correction-request/receipt/exchange",
    canonicalPath: "/correction-request/receipt",
  },
  {
    screenId: "PUB-030",
    exchangePath: "/subscription/manage/exchange",
    canonicalPath: "/subscription/manage",
  },
] as const;

for (const contract of contracts) {
  test(`${contract.screenId} dedicated exchange is no-store and no-referrer`, async ({
    request,
  }) => {
    const token = `headers-${randomUUID()}`;
    const response = await request.get(
      `${publicWeb}${contract.exchangePath}?token=${encodeURIComponent(token)}`,
      { maxRedirects: 0 },
    );

    expect(response.status()).toBe(303);
    expect(response.headers()["cache-control"]).toBe("no-store");
    expect(response.headers()["referrer-policy"]).toBe("no-referrer");
    const location = response.headers().location;
    expect(location).toBeDefined();
    if (!location) throw new Error("exchange redirect has no location");
    expect(new URL(location, publicWeb).pathname).toBe(contract.canonicalPath);
    expect(location).not.toContain(token);
    expect(location).not.toContain(encodeURIComponent(token));
  });

  for (const outcome of ["success", "failure"] as const) {
    test(`${contract.screenId} ${outcome} exchange leaves a token-free canonical URL and referrer`, async ({
      page,
    }) => {
      const token = `${outcome === "failure" ? "invalid-" : "accepted-"}${randomUUID()}`;
      let canonicalReferrer: string | undefined;
      page.on("request", (request) => {
        const target = new URL(request.url());
        if (
          request.isNavigationRequest() &&
          target.pathname === contract.canonicalPath
        )
          canonicalReferrer = request.headers().referer;
      });

      await page.goto(
        `${publicWeb}${contract.exchangePath}?token=${encodeURIComponent(token)}`,
        { waitUntil: "networkidle" },
      );

      const canonical = new URL(page.url());
      expect(canonical.pathname).toBe(contract.canonicalPath);
      expect(canonical.searchParams.has("token")).toBe(false);
      expect(page.url()).not.toContain(token);
      expect(page.url()).not.toContain(encodeURIComponent(token));
      expect(canonicalReferrer).toBeUndefined();
    });
  }

  test(`${contract.screenId} canonical page does not exchange a query token`, async ({
    page,
    request,
  }) => {
    const token = `canonical-side-door-${randomUUID()}`;
    const target = `${publicWeb}${contract.canonicalPath}?token=${encodeURIComponent(token)}`;
    const response = await request.get(target, { maxRedirects: 0 });
    expect(response.status()).toBe(303);
    expect(response.headers()["cache-control"]).toBe("no-store");
    expect(response.headers()["referrer-policy"]).toBe("no-referrer");
    const location = response.headers().location;
    expect(location).toBeDefined();
    if (!location) throw new Error("canonical redirect has no location");
    expect(location).not.toContain("token=");

    await page.goto(target, { waitUntil: "networkidle" });

    const canonical = new URL(page.url());
    expect(canonical.pathname).toBe(contract.canonicalPath);
    expect(canonical.searchParams.has("token")).toBe(false);
    expect(page.url()).not.toContain(token);
    expect(
      (await state(request)).submissionExchanges.some(
        (exchange) => exchange.tokenSha256 === sha256(token),
      ),
    ).toBe(false);
  });
}
