import { createHash, createHmac } from "node:crypto";

const PREFIX = "gurine-synth-v1";
const DOMAIN = "gurine-synthetic-proof-v1";
const MAX_AGE_SECONDS = 300;
const CLOCK_SKEW_SECONDS = 5;
const NONCE_PATTERN = /^[A-Za-z0-9_-]{16,128}$/;

export function bindSyntheticAbuseProof(
  body: Readonly<Record<string, unknown>>,
  input: {
    action: string;
    keyBase64: string;
    siteKey?: string | undefined;
    now?: number | undefined;
  },
): Record<string, unknown> {
  const proof = body.abuseProof;
  if (!isRecord(proof) || proof.provider !== "SYNTHETIC_TEST") {
    return { ...body };
  }
  if (input.siteKey !== "synthetic-test") {
    throw new Error("synthetic abuse proof is not enabled");
  }
  const action = proof.action;
  const issuedAt = proof.issuedAt;
  const nonce = proof.token;
  const now = input.now ?? Math.floor(Date.now() / 1000);
  if (
    action !== input.action ||
    !Number.isSafeInteger(issuedAt) ||
    (issuedAt as number) > now + CLOCK_SKEW_SECONDS ||
    now - (issuedAt as number) > MAX_AGE_SECONDS ||
    typeof nonce !== "string" ||
    !NONCE_PATTERN.test(nonce)
  ) {
    throw new Error("synthetic abuse proof request is invalid");
  }
  const key = Buffer.from(input.keyBase64, "base64");
  if (key.length < 32) throw new Error("synthetic abuse proof key is invalid");
  const kid = createHash("sha256").update(key).digest("hex").slice(0, 16);
  const message = [DOMAIN, action, String(issuedAt), nonce].join("\0");
  const signature = createHmac("sha256", key).update(message).digest("hex");
  return {
    ...body,
    abuseProof: {
      provider: "SYNTHETIC_TEST",
      token: `${PREFIX}.${kid}.${nonce}.${signature}`,
      action,
      issuedAt,
    },
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
