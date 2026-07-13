import { randomBytes } from "node:crypto";
import {
  type CookieEnvelopeKeyRing,
  isSubmissionSessionDescriptor,
  isSubmissionSessionPayload,
  openCookieEnvelope,
  type SubmissionSessionPayload,
  sealCookieEnvelope,
  submissionCookieForKind,
  submissionCookiesForPath,
} from "@gurine/config";
import type { RequestEvent } from "@sveltejs/kit";
import { env } from "$env/dynamic/private";

export function readSubmissionSession(
  event: RequestEvent,
): SubmissionSessionPayload | undefined {
  for (const spec of submissionCookiesForPath(event.url.pathname)) {
    const value = openCookieEnvelope(
      {
        prefix: "gurine-ssc-v1",
        cookieName: spec.name,
        origin: origin(),
        path: spec.path,
        sameSite: "Lax",
      },
      keys(),
      event.cookies.get(spec.name),
      isSubmissionSessionPayload,
    );
    if (
      value &&
      value.absoluteExpiresAt > now() &&
      spec.kinds.includes(value.sessionKind)
    )
      return value;
  }
  return undefined;
}

export function persistSubmissionSession(
  event: RequestEvent,
  response: Record<string, unknown>,
): boolean {
  const descriptor = [response.session, response.receiptSession].find(
    isSubmissionSessionDescriptor,
  );
  if (!descriptor) return false;
  clearSubmissionSessions(event);
  const spec = submissionCookieForKind(descriptor.sessionKind);
  const issuedAt = now();
  const value: SubmissionSessionPayload = {
    v: 1,
    typ: "submission-session",
    sessionKind: descriptor.sessionKind,
    opaqueSessionToken: descriptor.opaqueSessionToken,
    csrfToken: randomBytes(32).toString("base64url"),
    issuedAt,
    absoluteExpiresAt: Math.floor(Date.parse(descriptor.expiresAt) / 1000),
    csrfRotatedAt: issuedAt,
  };
  event.cookies.set(
    spec.name,
    sealCookieEnvelope(
      {
        prefix: "gurine-ssc-v1",
        cookieName: spec.name,
        origin: origin(),
        path: spec.path,
        sameSite: "Lax",
      },
      keys(),
      value,
    ),
    options(event, spec.path, Math.max(0, value.absoluteExpiresAt - issuedAt)),
  );
  return true;
}

export function clearSubmissionSessions(event: RequestEvent) {
  const seen = new Set<string>();
  for (const path of [event.url.pathname, "/respond/receipt", "/respond"]) {
    for (const spec of submissionCookiesForPath(path)) {
      if (seen.has(spec.name)) continue;
      seen.add(spec.name);
      event.cookies.delete(spec.name, options(event, spec.path, 0));
    }
  }
}

function keys(): CookieEnvelopeKeyRing {
  if (!env.SUBMISSION_COOKIE_KEY_CURRENT)
    throw new Error("SUBMISSION_COOKIE_KEY_CURRENT is missing");
  return {
    current: env.SUBMISSION_COOKIE_KEY_CURRENT,
    ...(env.SUBMISSION_COOKIE_KEY_PREVIOUS
      ? { previous: env.SUBMISSION_COOKIE_KEY_PREVIOUS }
      : {}),
  };
}
function origin(): string {
  if (!env.RESPONSE_BASE_URL) throw new Error("RESPONSE_BASE_URL is missing");
  return env.RESPONSE_BASE_URL;
}
function options(event: RequestEvent, path: string, maxAge: number) {
  return {
    path,
    httpOnly: true,
    secure: env.GURINE_ENV === "production" || event.url.protocol === "https:",
    sameSite: "lax" as const,
    maxAge,
  };
}
function now(): number {
  return Math.floor(Date.now() / 1000);
}
