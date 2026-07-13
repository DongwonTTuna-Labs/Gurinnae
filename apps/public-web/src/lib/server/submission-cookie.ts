import { randomBytes } from "node:crypto";
import {
  type CookieEnvelopeKeyRing,
  isSubmissionSessionDescriptor,
  isSubmissionSessionPayload,
  openCookieEnvelope,
  type SubmissionSessionKind,
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
  expectedKinds: readonly SubmissionSessionKind[],
): boolean {
  const descriptor = [
    response.session,
    response.pendingSession,
    response.receiptSession,
  ].find(isSubmissionSessionDescriptor);
  if (!descriptor || !expectedKinds.includes(descriptor.sessionKind))
    return false;
  clearSubmissionSessions(event);
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
  writeSubmissionSession(event, value);
  return true;
}

export function rotateSubmissionCsrf(event: RequestEvent): boolean {
  const current = readSubmissionSession(event);
  if (!current) return false;
  const rotatedAt = now();
  writeSubmissionSession(event, {
    ...current,
    csrfToken: randomBytes(32).toString("base64url"),
    csrfRotatedAt: rotatedAt,
  });
  return true;
}

function writeSubmissionSession(
  event: RequestEvent,
  value: SubmissionSessionPayload,
) {
  const spec = submissionCookieForKind(value.sessionKind);
  const issuedAt = now();
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
}

export function clearSubmissionSessions(event: RequestEvent) {
  const seen = new Set<string>();
  for (const path of [
    event.url.pathname,
    "/respond/receipt",
    "/correction-request/receipt",
    "/respond",
    "/correction-request",
    "/subscription",
  ]) {
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
  if (!env.PUBLIC_BASE_URL) throw new Error("PUBLIC_BASE_URL is missing");
  return env.PUBLIC_BASE_URL;
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
