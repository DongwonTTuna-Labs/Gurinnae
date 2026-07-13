import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import {
  chacha20Poly1305Open,
  chacha20Poly1305Seal,
} from "./chacha20-poly1305";

export type CookieEnvelopeKeyRing = {
  current: string;
  previous?: string;
};

export type CookieEnvelopeContext = {
  prefix: "gurine-sc-v1" | "gurine-ssc-v1" | "gurine-st-v1" | "gurine-su-v1";
  cookieName: string;
  origin: string;
  path: string;
  sameSite: "Lax" | "Strict";
};

export function sealCookieEnvelope(
  context: CookieEnvelopeContext,
  keys: CookieEnvelopeKeyRing,
  payload: unknown,
  nonce: Uint8Array = randomBytes(12),
): string {
  const key = decodeKey(keys.current);
  if (nonce.length !== 12)
    throw new Error("cookie envelope nonce must be 12 bytes");
  const plaintext = canonicalJson(payload);
  const ciphertext = chacha20Poly1305Seal(
    key,
    nonce,
    Buffer.from(plaintext, "utf8"),
    aad(context),
  );
  return `${context.prefix}.${keyId(key)}.${Buffer.from(nonce).toString("base64url")}.${ciphertext.toString("base64url")}`;
}

export function openCookieEnvelope<T>(
  context: CookieEnvelopeContext,
  keys: CookieEnvelopeKeyRing,
  token: string | undefined,
  validate: (value: unknown) => value is T,
): T | undefined {
  if (!token) return undefined;
  const parts = token.split(".");
  if (parts.length !== 4 || parts[0] !== context.prefix) return undefined;
  const [, kid, encodedNonce, encodedCiphertext] = parts;
  if (!kid || !encodedNonce || !encodedCiphertext) return undefined;
  let nonce: Buffer;
  let ciphertextAndTag: Buffer;
  try {
    nonce = Buffer.from(encodedNonce, "base64url");
    ciphertextAndTag = Buffer.from(encodedCiphertext, "base64url");
  } catch {
    return undefined;
  }
  if (nonce.length !== 12 || ciphertextAndTag.length < 17) return undefined;
  for (const encodedKey of [keys.current, keys.previous]) {
    if (!encodedKey) continue;
    let key: Buffer;
    try {
      key = decodeKey(encodedKey);
    } catch {
      continue;
    }
    if (!constantTimeTextEqual(keyId(key), kid)) continue;
    try {
      const plaintext = chacha20Poly1305Open(
        key,
        nonce,
        ciphertextAndTag,
        aad(context),
      );
      if (!plaintext) return undefined;
      const value: unknown = JSON.parse(plaintext.toString("utf8"));
      return validate(value) ? value : undefined;
    } catch {
      return undefined;
    }
  }
  return undefined;
}

export function canonicalCookieOrigin(value: string): string {
  const parsed = new URL(value);
  if (
    !matchesHttp(parsed) ||
    parsed.pathname !== "/" ||
    parsed.search ||
    parsed.hash
  ) {
    throw new Error("cookie origin must be an HTTP(S) origin");
  }
  return parsed.origin.toLowerCase();
}

export function canonicalJsonSha256(value: unknown): string {
  return createHash("sha256").update(canonicalJson(value)).digest("hex");
}

function decodeKey(value: string): Buffer {
  const key = Buffer.from(value, "base64");
  if (key.length !== 32)
    throw new Error("cookie envelope key must decode to 32 bytes");
  return key;
}

function keyId(key: Uint8Array): string {
  return createHash("sha256").update(key).digest("hex").slice(0, 16);
}

function aad(context: CookieEnvelopeContext): Buffer {
  return Buffer.from(
    [
      context.prefix,
      context.cookieName,
      canonicalCookieOrigin(context.origin),
      context.path,
      context.sameSite,
    ].join("\0"),
    "ascii",
  );
}

function canonicalJson(value: unknown): string {
  return JSON.stringify(sortJson(value));
}

function sortJson(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortJson);
  if (typeof value !== "object" || value === null) return value;
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, item]) => [key, sortJson(item)]),
  );
}

function constantTimeTextEqual(left: string, right: string): boolean {
  const leftBytes = Buffer.from(left, "ascii");
  const rightBytes = Buffer.from(right, "ascii");
  return (
    leftBytes.length === rightBytes.length &&
    timingSafeEqual(leftBytes, rightBytes)
  );
}

function matchesHttp(url: URL): boolean {
  return url.protocol === "http:" || url.protocol === "https:";
}
