import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { assertedRequest, serviceAssertionFetch } from "./assertion";

describe("service assertion request canonicalization", () => {
  it("forwards URLSearchParams spaces as RFC3986 percent encoding", async () => {
    let forwarded: Request | undefined;
    const capture = (async (
      resource: RequestInfo | URL,
      init?: RequestInit,
    ) => {
      forwarded =
        resource instanceof Request ? resource : new Request(resource, init);
      return new Response(null, { status: 204 });
    }) as typeof globalThis.fetch;
    const signedFetch = serviceAssertionFetch({
      fetch: capture,
      keyBase64: Buffer.alloc(32, 7).toString("base64"),
      issuer: "review-console",
      audience: "identity-api",
    });

    await signedFetch(
      new Request(
        "https://identity.test/search?term=two+words&%C3%A9=1&z=2&literal=a%2Bb",
      ),
    );

    expect(forwarded).toBeDefined();
    const captured = forwarded as Request;
    expect(new URL(captured.url).search).toBe(
      "?literal=a%2Bb&term=two%20words&z=2&%C3%A9=1",
    );
    const assertion = captured.headers.get("x-gurine-service-assertion");
    expect(assertion).not.toBeNull();
    const payload = JSON.parse(
      Buffer.from(assertion?.split(".")[2] ?? "", "base64url").toString("utf8"),
    ) as { querySha256: string };
    expect(payload.querySha256).toBe(
      createHash("sha256")
        .update("literal=a%2Bb&term=two%20words&z=2&%C3%A9=1")
        .digest("hex"),
    );
  });

  it("forwards assertedRequest query bytes exactly as signed", async () => {
    let forwarded: Request | undefined;
    const capture = (async (
      resource: RequestInfo | URL,
      init?: RequestInit,
    ) => {
      forwarded =
        resource instanceof Request ? resource : new Request(resource, init);
      return new Response(null, { status: 204 });
    }) as typeof globalThis.fetch;

    await assertedRequest({
      fetch: capture,
      baseUrl: "https://identity.test",
      keyBase64: Buffer.alloc(32, 7).toString("base64"),
      issuer: "review-console",
      audience: "identity-api",
      method: "GET",
      path: "/search",
      rawQuery: "term=two+words&literal=a%2Bb",
    });

    expect(forwarded).toBeDefined();
    const captured = forwarded as Request;
    expect(new URL(captured.url).search).toBe(
      "?literal=a%2Bb&term=two%20words",
    );
    const assertion = captured.headers.get("x-gurine-service-assertion");
    expect(assertion).not.toBeNull();
    const payload = JSON.parse(
      Buffer.from(assertion?.split(".")[2] ?? "", "base64url").toString("utf8"),
    ) as { querySha256: string };
    expect(payload.querySha256).toBe(
      createHash("sha256")
        .update("literal=a%2Bb&term=two%20words")
        .digest("hex"),
    );
  });
});
