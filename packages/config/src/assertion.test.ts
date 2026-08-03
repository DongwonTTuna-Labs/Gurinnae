import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  assertedRequest,
  serviceAssertion,
  serviceAssertionFetch,
} from "./assertion";

const payload = (assertion: string): Record<string, unknown> =>
  JSON.parse(
    Buffer.from(assertion.split(".")[2] ?? "", "base64url").toString("utf8"),
  ) as Record<string, unknown>;

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

  it("hash-binds and forwards an opaque next submission session", async () => {
    const nextSession = "A".repeat(43);
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
      issuer: "response-portal",
      audience: "submission-api",
      additionalHeaders: {
        "X-Gurine-Next-Submission-Session": nextSession,
      },
    });

    await signedFetch(
      new Request(
        "https://submission.test/v1/internal/privacy-requests/exchange",
        { method: "POST", body: "{}" },
      ),
    );

    expect(forwarded).toBeDefined();
    const captured = forwarded as Request;
    expect(captured.headers.get("x-gurine-next-submission-session")).toBe(
      nextSession,
    );
    const assertion = captured.headers.get("x-gurine-service-assertion") ?? "";
    const claims = payload(assertion);
    expect(claims.nextSubmissionSessionSha256).toBe(
      createHash("sha256").update(nextSession).digest("hex"),
    );
    expect(JSON.stringify(claims)).not.toContain(nextSession);
  });

  it("preserves the absent service assertion payload shape", () => {
    const assertion = serviceAssertion({
      keyBase64: Buffer.alloc(32, 7).toString("base64"),
      issuer: "review-console",
      audience: "identity-api",
      method: "GET",
      path: "/internal/v1/sessions/resolve",
      body: "",
      contentType: "",
    });

    expect(payload(assertion)).not.toHaveProperty(
      "nextSubmissionSessionSha256",
    );
  });

  it("rejects empty and duplicate next submission session headers", async () => {
    expect(() =>
      serviceAssertion({
        keyBase64: Buffer.alloc(32, 7).toString("base64"),
        issuer: "response-portal",
        audience: "submission-api",
        method: "POST",
        path: "/v1/internal/privacy-requests/exchange",
        body: "{}",
        contentType: "application/json",
        nextSubmissionSession: "",
      }),
    ).toThrow("next submission session header is invalid");

    const signedFetch = serviceAssertionFetch({
      fetch: async () => new Response(null, { status: 204 }),
      keyBase64: Buffer.alloc(32, 7).toString("base64"),
      issuer: "response-portal",
      audience: "submission-api",
      additionalHeaders: {
        "x-gurine-next-submission-session": "B".repeat(43),
      },
    });
    await expect(
      signedFetch(
        new Request(
          "https://submission.test/v1/internal/privacy-requests/exchange",
          {
            method: "POST",
            body: "{}",
            headers: {
              "X-Gurine-Next-Submission-Session": "A".repeat(43),
            },
          },
        ),
      ),
    ).rejects.toThrow("duplicate next submission session header");
  });
});
