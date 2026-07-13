import {
  type CookieEnvelopeContext,
  type CookieEnvelopeKeyRing,
  openCookieEnvelope,
  sealCookieEnvelope,
} from "@gurine/config";
import type { RequestEvent } from "@sveltejs/kit";
import { env } from "$env/dynamic/private";

export const SESSION_COOKIE = "gurine_internal_session";
export const OIDC_TRANSACTION_COOKIE = "gurine_oidc_transaction";
export const STEP_UP_TRANSACTION_COOKIE = "gurine_step_up_transaction";
export const STEP_UP_AUTHORIZATION_COOKIE = "gurine_step_up_authorization";
export const PENDING_ACTION_COOKIE = "gurine_pending_action";

export type InternalSession = {
  v: 1;
  typ: "internal-session";
  opaqueIdentitySessionToken: string;
  csrfToken: string;
  issuedAt: number;
  absoluteExpiresAt: number;
  csrfRotatedAt: number;
};

export type StepUpTransaction = {
  v: 1;
  typ: "step-up-transaction";
  transactionCookieValue: string;
  idempotencyKey: string;
  actionDigest: string;
  issuedAt: number;
  expiresAt: number;
};

export type StepUpAuthorization = {
  v: 1;
  typ: "step-up-authorization";
  authorizationId: string;
  authorizationToken: string;
  actionDigest: string;
  idempotencyKey: string;
  idempotencyKeySha256: string;
  maxAssertionIssues: 3;
  issuedAt: number;
  expiresAt: number;
};

export function readInternalSession(
  event: RequestEvent,
): InternalSession | undefined {
  const value = openCookieEnvelope(
    sessionContext(),
    keys(),
    event.cookies.get(SESSION_COOKIE),
    isInternalSession,
  );
  return value && value.absoluteExpiresAt > now() ? value : undefined;
}

export function setInternalSession(
  event: RequestEvent,
  value: InternalSession,
) {
  event.cookies.set(
    SESSION_COOKIE,
    sealCookieEnvelope(sessionContext(), keys(), value),
    cookieOptions(
      event,
      "/",
      "lax",
      Math.max(0, value.absoluteExpiresAt - now()),
    ),
  );
}

export function readStepUpTransaction(
  event: RequestEvent,
): StepUpTransaction | undefined {
  const value = openCookieEnvelope(
    stepUpTransactionContext(STEP_UP_TRANSACTION_COOKIE),
    keys(),
    event.cookies.get(STEP_UP_TRANSACTION_COOKIE),
    isStepUpTransaction,
  );
  return value && value.expiresAt > now() ? value : undefined;
}

export function setStepUpTransaction(
  event: RequestEvent,
  value: StepUpTransaction,
) {
  event.cookies.set(
    STEP_UP_TRANSACTION_COOKIE,
    sealCookieEnvelope(
      stepUpTransactionContext(STEP_UP_TRANSACTION_COOKIE),
      keys(),
      value,
    ),
    cookieOptions(
      event,
      "/auth/step-up/callback",
      "lax",
      Math.max(0, value.expiresAt - now()),
    ),
  );
}

export function readStepUpAuthorization(
  event: RequestEvent,
): StepUpAuthorization | undefined {
  const value = openCookieEnvelope(
    stepUpAuthorizationContext(),
    keys(),
    event.cookies.get(STEP_UP_AUTHORIZATION_COOKIE),
    isStepUpAuthorization,
  );
  return value && value.expiresAt > now() ? value : undefined;
}

export function setStepUpAuthorization(
  event: RequestEvent,
  value: StepUpAuthorization,
) {
  event.cookies.set(
    STEP_UP_AUTHORIZATION_COOKIE,
    sealCookieEnvelope(stepUpAuthorizationContext(), keys(), value),
    cookieOptions(
      event,
      "/internal",
      "strict",
      Math.max(0, value.expiresAt - now()),
    ),
  );
}

export function readPending<T>(
  event: RequestEvent,
  validate: (value: unknown) => value is T,
): T | undefined {
  return openCookieEnvelope(
    stepUpTransactionContext(PENDING_ACTION_COOKIE),
    keys(),
    event.cookies.get(PENDING_ACTION_COOKIE),
    validate,
  );
}

export function setPending(event: RequestEvent, value: unknown) {
  event.cookies.set(
    PENDING_ACTION_COOKIE,
    sealCookieEnvelope(
      stepUpTransactionContext(PENDING_ACTION_COOKIE),
      keys(),
      value,
    ),
    cookieOptions(event, "/auth/step-up/callback", "lax", 600),
  );
}

export function setLoginTransaction(event: RequestEvent, value: string) {
  event.cookies.set(
    OIDC_TRANSACTION_COOKIE,
    value,
    cookieOptions(event, "/auth/callback", "lax", 600),
  );
}

export function clearLoginTransaction(event: RequestEvent) {
  event.cookies.delete(
    OIDC_TRANSACTION_COOKIE,
    cookieOptions(event, "/auth/callback", "lax", 0),
  );
}

export function clearStepUpState(event: RequestEvent) {
  event.cookies.delete(
    STEP_UP_TRANSACTION_COOKIE,
    cookieOptions(event, "/auth/step-up/callback", "lax", 0),
  );
  event.cookies.delete(
    PENDING_ACTION_COOKIE,
    cookieOptions(event, "/auth/step-up/callback", "lax", 0),
  );
}

export function clearStepUpAuthorization(event: RequestEvent) {
  event.cookies.delete(
    STEP_UP_AUTHORIZATION_COOKIE,
    cookieOptions(event, "/internal", "strict", 0),
  );
}

export function clearAuth(event: RequestEvent) {
  event.cookies.delete(SESSION_COOKIE, cookieOptions(event, "/", "lax", 0));
  clearLoginTransaction(event);
  clearStepUpState(event);
  clearStepUpAuthorization(event);
}

function sessionContext(): CookieEnvelopeContext {
  return {
    prefix: "gurine-sc-v1",
    cookieName: SESSION_COOKIE,
    origin: origin(),
    path: "/",
    sameSite: "Lax",
  };
}

function stepUpTransactionContext(cookieName: string): CookieEnvelopeContext {
  return {
    prefix: "gurine-st-v1",
    cookieName,
    origin: origin(),
    path: "/auth/step-up/callback",
    sameSite: "Lax",
  };
}

function stepUpAuthorizationContext(): CookieEnvelopeContext {
  return {
    prefix: "gurine-su-v1",
    cookieName: STEP_UP_AUTHORIZATION_COOKIE,
    origin: origin(),
    path: "/internal",
    sameSite: "Strict",
  };
}

function keys(): CookieEnvelopeKeyRing {
  const current = env.SESSION_COOKIE_KEY_CURRENT;
  if (!current) throw new Error("SESSION_COOKIE_KEY_CURRENT is missing");
  return {
    current,
    ...(env.SESSION_COOKIE_KEY_PREVIOUS
      ? { previous: env.SESSION_COOKIE_KEY_PREVIOUS }
      : {}),
  };
}

function origin(): string {
  if (!env.REVIEW_BASE_URL) throw new Error("REVIEW_BASE_URL is missing");
  return env.REVIEW_BASE_URL;
}

function cookieOptions(
  event: RequestEvent,
  path: string,
  sameSite: "lax" | "strict",
  maxAge: number,
) {
  return {
    path,
    httpOnly: true,
    secure: env.GURINE_ENV === "production" || event.url.protocol === "https:",
    sameSite,
    maxAge,
  } as const;
}

function isInternalSession(value: unknown): value is InternalSession {
  if (!isRecord(value)) return false;
  return (
    value.v === 1 &&
    value.typ === "internal-session" &&
    token(value.opaqueIdentitySessionToken, 43, 256) &&
    token(value.csrfToken, 43, 128) &&
    integer(value.issuedAt) &&
    integer(value.absoluteExpiresAt) &&
    integer(value.csrfRotatedAt)
  );
}

function isStepUpTransaction(value: unknown): value is StepUpTransaction {
  if (!isRecord(value)) return false;
  return (
    value.v === 1 &&
    value.typ === "step-up-transaction" &&
    token(value.transactionCookieValue, 43, 256) &&
    token(value.idempotencyKey, 16, 200) &&
    hash(value.actionDigest) &&
    integer(value.issuedAt) &&
    integer(value.expiresAt)
  );
}

function isStepUpAuthorization(value: unknown): value is StepUpAuthorization {
  if (!isRecord(value)) return false;
  return (
    value.v === 1 &&
    value.typ === "step-up-authorization" &&
    typeof value.authorizationId === "string" &&
    token(value.authorizationToken, 43, 256) &&
    token(value.idempotencyKey, 16, 200) &&
    hash(value.actionDigest) &&
    hash(value.idempotencyKeySha256) &&
    value.maxAssertionIssues === 3 &&
    integer(value.issuedAt) &&
    integer(value.expiresAt)
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function token(
  value: unknown,
  minimum: number,
  maximum: number,
): value is string {
  return (
    typeof value === "string" &&
    value.length >= minimum &&
    value.length <= maximum &&
    /^[A-Za-z0-9_-]+$/.test(value)
  );
}
function hash(value: unknown): value is string {
  return typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
}
function integer(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}
function now(): number {
  return Math.floor(Date.now() / 1000);
}
