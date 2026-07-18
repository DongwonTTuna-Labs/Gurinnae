import { createHash, createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import { bindSyntheticAbuseProof } from "./synthetic-proof";

const key = Buffer.from("01234567890123456789012345678901");
const keyBase64 = key.toString("base64");
const action = "createSubscription";
const issuedAt = 1_783_987_200;
const nonce = "12345678-1234-4234-8234-123456789012";

describe("synthetic abuse proof binding", () => {
  it("replaces the browser nonce with a short-lived BFF signature", () => {
    const bound = bindSyntheticAbuseProof(
      {
        email: "reader@example.test",
        abuseProof: {
          provider: "SYNTHETIC_TEST",
          token: nonce,
          action,
          issuedAt,
        },
      },
      { action, keyBase64, siteKey: "synthetic-test", now: issuedAt + 1 },
    );
    const kid = createHash("sha256").update(key).digest("hex").slice(0, 16);
    const signature = createHmac("sha256", key)
      .update(
        ["gurine-synthetic-proof-v1", action, String(issuedAt), nonce].join(
          "\0",
        ),
      )
      .digest("hex");
    expect(bound.abuseProof).toEqual({
      provider: "SYNTHETIC_TEST",
      token: `gurine-synth-v1.${kid}.${nonce}.${signature}`,
      action,
      issuedAt,
    });
  });

  it("rejects stale, action-confused, or production-misconfigured requests", () => {
    const proof = {
      abuseProof: {
        provider: "SYNTHETIC_TEST",
        token: nonce,
        action,
        issuedAt,
      },
    };
    expect(() =>
      bindSyntheticAbuseProof(proof, {
        action,
        keyBase64,
        siteKey: "synthetic-test",
        now: issuedAt + 301,
      }),
    ).toThrow("invalid");
    expect(() =>
      bindSyntheticAbuseProof(proof, {
        action: "createContactRequest",
        keyBase64,
        siteKey: "synthetic-test",
        now: issuedAt,
      }),
    ).toThrow("invalid");
    expect(() =>
      bindSyntheticAbuseProof(proof, {
        action,
        keyBase64,
        siteKey: "turnstile-site-key",
        now: issuedAt,
      }),
    ).toThrow("not enabled");
  });
});
