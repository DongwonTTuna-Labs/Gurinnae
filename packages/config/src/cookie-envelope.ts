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
  return writeJson(sortJson(value));
}

function sortJson(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortJson);
  if (typeof value !== "object" || value === null) return value;
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .sort(([left], [right]) => compareUtf16(left, right))
      .map(([key, item]) => [key, sortJson(item)]),
  );
}

function compareUtf16(left: string, right: string): number {
  const units = (value: string): number[] =>
    Array.from(value).flatMap((item) => {
      const code = item.codePointAt(0) ?? 0;
      return code > 0xffff
        ? [
            0xd800 + ((code - 0x10000) >> 10),
            0xdc00 + ((code - 0x10000) & 0x3ff),
          ]
        : [code];
    });
  const a = units(left);
  const b = units(right);
  const length = Math.min(a.length, b.length);
  for (let index = 0; index < length; index += 1) {
    if (a[index] !== b[index]) return (a[index] ?? 0) - (b[index] ?? 0);
  }
  return a.length - b.length;
}

function writeJson(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value))
      throw new Error("canonical JSON accepts only safe integers");
    return String(value);
  }
  if (Array.isArray(value)) return `[${value.map(writeJson).join(",")}]`;
  if (typeof value === "object") {
    return `{${Object.entries(value as Record<string, unknown>)
      .map(([key, item]) => `${JSON.stringify(key)}:${writeJson(item)}`)
      .join(",")}}`;
  }
  throw new Error("unsupported canonical JSON value");
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
