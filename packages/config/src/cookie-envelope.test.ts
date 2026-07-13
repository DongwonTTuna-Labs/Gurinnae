import { describe, expect, test } from "vitest";
import {
  canonicalJsonSha256,
  openCookieEnvelope,
  sealCookieEnvelope,
} from "./cookie-envelope";

const key = Buffer.from(
  "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
  "hex",
).toString("base64");

describe("authority cookie envelope vectors", () => {
  test("internal session vector matches byte-for-byte", () => {
    const payload = {
      v: 1,
      typ: "internal-session",
      opaqueIdentitySessionToken:
        "test-only-opaque-session-token-43-characters-0000000",
      csrfToken: "test-only-csrf-token-43-characters-00000000000",
      issuedAt: 1783828800,
      absoluteExpiresAt: 1783872000,
      csrfRotatedAt: 1783828800,
    };
    const context = {
      prefix: "gurine-sc-v1" as const,
      cookieName: "gurine_internal_session",
      origin: "https://review.gurine.invalid",
      path: "/",
      sameSite: "Lax" as const,
    };
    const token = sealCookieEnvelope(
      context,
      { current: key },
      payload,
      Buffer.from("000102030405060708090a0b", "hex"),
    );
    expect(token).toBe(
      "gurine-sc-v1.630dcd2966c43366.AAECAwQFBgcICQoL.8tlpYlp4yTXD5nqL6HR8BroxxsVrRZqB1a8Y90XwlhDO41-BgEze7FZGE7wk4K0ZT7ORR8UagKMiiPUl8zzssC0X16iLNhbLsHM-yDUTsp2j8yRBHQzdSmE8lWD1STGSLrYNgZa6U5HDKN6HkqGHsNlfZgi5bWLUbQRHrAxa2wfVRPmMngvsVHsrR0ocEElVxBD2B24mqDtclc5F3UjFSkzQ7obpK_-D4FxcMhPUnHTzO8gmbnYVZblum_RKRfFjqi4w4U6JYHRIJgg6_msOZQOqpF8Sat0kOxkclcsqTM1ObyjE98An2viTZjLOavrtnHLYnRgIw_HQokf5k987E_4LL8yTcwK7N7X4hniHY4bz",
    );
    expect(
      openCookieEnvelope(context, { current: key }, token, isRecord),
    ).toEqual(payload);
  });

  test("AAD mismatch and unknown key fail closed", () => {
    const context = {
      prefix: "gurine-ssc-v1" as const,
      cookieName: "gurine_response_session",
      origin: "https://respond.gurine.invalid",
      path: "/respond",
      sameSite: "Lax" as const,
    };
    const token = sealCookieEnvelope(context, { current: key }, { v: 1 });
    expect(
      openCookieEnvelope(
        { ...context, path: "/" },
        { current: key },
        token,
        isRecord,
      ),
    ).toBeUndefined();
    expect(
      openCookieEnvelope(
        context,
        { current: Buffer.alloc(32, 7).toString("base64") },
        token,
        isRecord,
      ),
    ).toBeUndefined();
  });

  test("step-up action digest matches the Rust key-sorted contract", () => {
    expect(
      canonicalJsonSha256({
        operationId: "activateRuleVersion",
        aggregateType: "core.rule_version",
        aggregateId: "11111111-1111-4111-8111-111111111111",
        expectedVersion: 7,
        businessPayloadSha256: "1".repeat(64),
        idempotencyKeySha256: "2".repeat(64),
      }),
    ).toBe("d1015e3f8759b26cdc1446a5b042155099f8bfe98d68141523feee543efc5d6a");
  });
});

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
