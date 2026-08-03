import { createHmac } from "node:crypto";

const ANONYMOUS_OPERATIONS = new Set([
  "createContactRequest",
  "createCorrectionRequestDraft",
  "createDatasetExport",
  "createSubscription",
]);

type Bucket = {
  count: number;
  resetAt: number;
};

type Limit = {
  attempts: number;
  windowMs: number;
};

export type AnonymousRateLimitRequest = {
  clientAddress: string;
  operationId: string;
  destination: string;
  key: string;
};

export type AnonymousRateLimitResult =
  | { allowed: true }
  | { allowed: false; retryAfterSeconds: number };

const IP_LIMIT: Limit = { attempts: 20, windowMs: 10 * 60 * 1_000 };
const DESTINATION_LIMIT: Limit = {
  attempts: 5,
  windowMs: 60 * 60 * 1_000,
};
const MAX_BUCKETS = 20_000;

export class AnonymousSubmissionRateLimiter {
  readonly #buckets = new Map<string, Bucket>();
  readonly #now: () => number;
  readonly #ipLimit: Limit;
  readonly #destinationLimit: Limit;
  readonly #maxBuckets: number;

  constructor(
    options: {
      now?: () => number;
      ipLimit?: Limit;
      destinationLimit?: Limit;
      maxBuckets?: number;
    } = {},
  ) {
    this.#now = options.now ?? Date.now;
    this.#ipLimit = options.ipLimit ?? IP_LIMIT;
    this.#destinationLimit = options.destinationLimit ?? DESTINATION_LIMIT;
    this.#maxBuckets = options.maxBuckets ?? MAX_BUCKETS;
  }

  consume(request: AnonymousRateLimitRequest): AnonymousRateLimitResult {
    if (!ANONYMOUS_OPERATIONS.has(request.operationId))
      return { allowed: true };
    const now = this.#now();
    const ipKey = digest(
      request.key,
      `ip\u0000${request.operationId}\u0000${request.clientAddress}`,
    );
    const destinationKey = digest(
      request.key,
      `destination\u0000${request.operationId}\u0000${request.destination}`,
    );
    this.#prune(now, [ipKey, destinationKey]);
    if (
      (!this.#buckets.has(ipKey) || !this.#buckets.has(destinationKey)) &&
      this.#buckets.size + 2 > this.#maxBuckets
    ) {
      return { allowed: false, retryAfterSeconds: 60 };
    }

    const ip = this.#bucket(ipKey, now, this.#ipLimit.windowMs);
    const destination = this.#bucket(
      destinationKey,
      now,
      this.#destinationLimit.windowMs,
    );
    if (
      ip.count >= this.#ipLimit.attempts ||
      destination.count >= this.#destinationLimit.attempts
    ) {
      return {
        allowed: false,
        retryAfterSeconds: Math.max(
          1,
          Math.ceil(
            (Math.max(
              ip.count >= this.#ipLimit.attempts ? ip.resetAt : now,
              destination.count >= this.#destinationLimit.attempts
                ? destination.resetAt
                : now,
            ) -
              now) /
              1_000,
          ),
        ),
      };
    }
    ip.count += 1;
    destination.count += 1;
    return { allowed: true };
  }

  #bucket(key: string, now: number, windowMs: number): Bucket {
    const current = this.#buckets.get(key);
    if (current && current.resetAt > now) return current;
    const created = { count: 0, resetAt: now + windowMs };
    this.#buckets.set(key, created);
    return created;
  }

  #prune(now: number, incoming: readonly string[]): void {
    if (this.#buckets.size < this.#maxBuckets / 2) return;
    const protectedKeys = new Set(incoming);
    for (const [key, bucket] of this.#buckets) {
      if (bucket.resetAt <= now && !protectedKeys.has(key))
        this.#buckets.delete(key);
    }
  }
}

export const anonymousSubmissionRateLimiter =
  new AnonymousSubmissionRateLimiter();

export function isAnonymousSubmissionOperation(operationId: string): boolean {
  return ANONYMOUS_OPERATIONS.has(operationId);
}

export function anonymousDestination(
  operationId: string,
  payload: Readonly<Record<string, unknown>>,
  clientAddress: string,
): string {
  const email = canonicalString(payload.email);
  if (email) return `email:${email.toLowerCase()}`;
  if (operationId === "createDatasetExport")
    return `dataset:${canonicalString(payload.datasetId) ?? clientAddress}`;
  if (operationId === "createCorrectionRequestDraft") {
    const caseSlug = canonicalString(payload.caseSlug);
    const revision = canonicalString(payload.publicationRevision);
    return caseSlug
      ? `case:${caseSlug.toLowerCase()}:${revision ?? "latest"}`
      : `client:${clientAddress}`;
  }
  return `client:${clientAddress}`;
}

function canonicalString(value: unknown): string | undefined {
  if (typeof value !== "string" && typeof value !== "number") return undefined;
  const text = String(value).trim();
  return text.length > 0 ? text.slice(0, 512) : undefined;
}

function digest(key: string, value: string): string {
  return createHmac("sha256", key).update(value).digest("hex");
}
