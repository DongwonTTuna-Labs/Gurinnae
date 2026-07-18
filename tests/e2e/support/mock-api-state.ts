import { createHash, randomUUID } from "node:crypto";

export const port = Number(process.env.MOCK_API_PORT ?? "29100");

const expiresAt = () => new Date(Date.now() + 15 * 60_000).toISOString();
const token = (seed: string) =>
  createHash("sha384").update(seed).digest("base64url");
const sha256 = (value: string | Uint8Array) =>
  createHash("sha256").update(value).digest("hex");
const sortJson = (value: unknown): unknown => {
  if (Array.isArray(value)) return value.map(sortJson);
  if (typeof value !== "object" || value === null) return value;
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, item]) => [key, sortJson(item)]),
  );
};
const canonicalJsonSha256 = (value: unknown) =>
  sha256(JSON.stringify(sortJson(value)));

type LoginTransaction = { returnTo: string; callbackUri: string };
type StepUpTransaction = {
  returnTo: string;
  callbackUri: string;
  actionContext: Record<string, unknown>;
};
type CommandAttempt = {
  bodySha256: string;
  idempotencyKeySha256: string;
  actorAssertionSha256: string;
};
export type AttachmentUpload = {
  id: string;
  kind: "correction" | "response";
  filename: string;
  mediaType: string;
  sizeBytes: number;
  sha256: string;
  sessionTokenSha256: string;
  uploaded: boolean;
  finalized: boolean;
};

export const runtime = {
  loginTransactions: new Map<string, LoginTransaction>(),
  stepUpTransactions: new Map<string, StepUpTransaction>(),
  activeSession: token("internal-session"),
  currentCsrf: token("csrf-initial"),
  sessionRevoked: false,
  actorAssertionSerial: 0,
  sessionResolveCount: 0,
  stepUpStartCount: 0,
  stepUpCallbackCount: 0,
  authorizationCloseCount: 0,
  sessionRevokeCount: 0,
  commandAttempts: [] as CommandAttempt[],
  assertionOperations: [] as Array<{
    operationId: string;
    actorAssertionSha256: string;
  }>,
  submissionExchanges: [] as Array<{
    path: string;
    tokenSha256: string;
    sessionKind: string;
    idempotencyKeySha256: string;
    accepted: boolean;
  }>,
  consumedOneTimeTokens: new Set<string>(),
  exchangeReplays: new Map<
    string,
    { bodySha256: string; response: Record<string, unknown> }
  >(),
  submissionReads: [] as Array<{ path: string; sessionTokenSha256: string }>,
  submissionWrites: [] as Array<{
    method: string;
    path: string;
    sessionTokenSha256: string;
    bodySha256: string;
    scopeType?: string;
    scopeRef?: string;
  }>,
  attachmentUploads: new Map<string, AttachmentUpload>(),
  correctionDraftVersion: 1,
  responseDraftVersion: 3,
};

function resetAll() {
  runtime.loginTransactions.clear();
  runtime.stepUpTransactions.clear();
  runtime.activeSession = token(`internal-session-${randomUUID()}`);
  runtime.currentCsrf = token(`csrf-${randomUUID()}`);
  runtime.sessionRevoked = false;
  runtime.consumedOneTimeTokens.clear();
  runtime.exchangeReplays.clear();
  clearObservations();
}
function clearObservations() {
  runtime.actorAssertionSerial = 0;
  runtime.sessionResolveCount = 0;
  runtime.stepUpStartCount = 0;
  runtime.stepUpCallbackCount = 0;
  runtime.authorizationCloseCount = 0;
  runtime.sessionRevokeCount = 0;
  runtime.commandAttempts = [];
  runtime.assertionOperations = [];
}
function actor() {
  return {
    actorId: "00000000-0000-4000-8000-000000000001",
    subject: "e2e-reviewer",
    displayName: "E2E 검토자",
    roles: ["administrator", "publisher"],
    capabilities: [
      "publication.publish",
      "cases.investigate",
      "review.editorial",
      "sources.operate",
      "kill_switch.execute",
      "admin.users.manage",
      "admin.roles.manage",
      "audit.export",
    ],
  };
}
function problem(status: number, code: string, title = code) {
  return Response.json(
    { type: "about:blank", title, status, code },
    { status, headers: { "content-type": "application/problem+json" } },
  );
}
function attachmentStatus(item: AttachmentUpload) {
  return {
    id: item.id,
    filename: item.filename,
    mediaType: item.mediaType,
    sizeBytes: item.sizeBytes,
    sha256: item.sha256,
    uploadStatus: item.finalized ? "FINALIZED" : "PENDING",
    scanStatus: item.finalized ? "PENDING" : "NOT_STARTED",
    publicationConsent: false,
  };
}
async function body(request: Request): Promise<Record<string, unknown>> {
  const value: unknown = await request.json().catch(() => undefined);
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}
function asserted(request: Request): boolean {
  const assertion = request.headers.get("x-gurine-service-assertion");
  return (
    assertion?.startsWith("gurine-sa-v1.") === true &&
    Boolean(request.headers.get("x-request-id"))
  );
}
function callbackUrl(callbackUri: string, kind: "login" | "step-up") {
  const url = new URL(callbackUri);
  url.searchParams.set("code", `${kind}-code`);
  url.searchParams.set("state", `${kind}-state`);
  url.searchParams.set("iss", "https://synthetic-idp.invalid");
  return url.toString();
}
export function testState() {
  return {
    sessionResolveCount: runtime.sessionResolveCount,
    stepUpStartCount: runtime.stepUpStartCount,
    stepUpCallbackCount: runtime.stepUpCallbackCount,
    authorizationCloseCount: runtime.authorizationCloseCount,
    sessionRevokeCount: runtime.sessionRevokeCount,
    sessionRevoked: runtime.sessionRevoked,
    commandAttempts: runtime.commandAttempts,
    assertionOperations: runtime.assertionOperations,
    submissionExchanges: runtime.submissionExchanges,
    submissionReads: runtime.submissionReads,
    submissionWrites: runtime.submissionWrites,
    attachmentUploads: [...runtime.attachmentUploads.values()],
  };
}
export {
  actor,
  asserted,
  attachmentStatus,
  body,
  callbackUrl,
  canonicalJsonSha256,
  clearObservations,
  expiresAt,
  problem,
  resetAll,
  sha256,
  sortJson,
  token,
};
