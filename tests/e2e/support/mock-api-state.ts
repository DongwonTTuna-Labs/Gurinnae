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

export const providerControlOperationIds = [
  "disableProviderRouting",
  "testProviderConnection",
  "upgradeProviderModel",
  "setModelAutoUpgrade",
] as const;
export type ProviderControlOperationId =
  (typeof providerControlOperationIds)[number];
export const providerControlPolicies = Object.freeze({
  disableProviderRouting: {
    capability: "kill_switch.execute",
    assurance: "STEP_UP",
  },
  testProviderConnection: {
    capability: "jobs.operate",
    assurance: "ACTIVE_SESSION",
  },
  upgradeProviderModel: {
    capability: "kill_switch.execute",
    assurance: "STEP_UP",
  },
  setModelAutoUpgrade: {
    capability: "kill_switch.execute",
    assurance: "STEP_UP",
  },
} as const satisfies Record<
  ProviderControlOperationId,
  {
    capability: string;
    assurance: "ACTIVE_SESSION" | "STEP_UP";
  }
>);
export type ProviderControlTarget = {
  targetType: "CAPABILITY";
  targetId: string;
  expectedVersion: number;
};
export type RelayDataPolicyInput = {
  processingRegion: string;
  retentionMode: "ZERO_RETENTION" | "BOUNDED_PROVIDER_RETENTION" | "LOCAL_ONLY";
  policyVersion: string;
};
export type ProviderControlCommand =
  | {
      operationId: "disableProviderRouting";
      providerId: string;
      reason: string;
      expectedVersion: number;
    }
  | {
      operationId: "testProviderConnection";
      providerId: string;
      testModel: string;
      reason?: string;
      expectedVersion: number;
    }
  | {
      operationId: "upgradeProviderModel";
      providerId: string;
      modelId: string;
      expectedVersion: number;
      reason: string;
      dataPolicy?: RelayDataPolicyInput;
    }
  | {
      operationId: "setModelAutoUpgrade";
      providerId: string;
      expectedVersion: number;
      enabled: boolean;
      track?: string;
      reason: string;
    };
export type ProviderControlProposal = {
  proposalId: string;
  version: number;
  state: "DRAFT" | "PENDING_QUORUM" | "APPROVED" | "REJECTED";
  contentDigest: string;
  approvalDigest: string;
  target: ProviderControlTarget;
  origin: Record<string, unknown>;
  payload: {
    schemaVersion: "action-payload.v1";
    kind: "PROVIDER_CONTROL";
    target: ProviderControlTarget;
    rationale: Record<string, unknown>;
    effect: Record<string, unknown>;
    providerControl: ProviderControlCommand;
  };
  rationale: Record<string, unknown>;
  expiresAt: string;
  createdAt: string;
  updatedAt: string;
  previewId: string | null;
  previewVersion: number | null;
  previewDigest: string | null;
  assignmentId: string | null;
  assignmentVersion: number | null;
  assignmentState: "ASSIGNED" | "IN_PROGRESS" | "COMPLETED" | null;
  decisionId: string | null;
  decision: "APPROVE" | "REJECT" | null;
  executionId: string | null;
  executionJobId: string | null;
  executionReceiptId: string | null;
};

/**
 * Stateful addendum fixture used by the INT-002 browser journey.  The
 * review-console is still exercised through its BFF and generated control
 * client; these values only provide a deterministic, server-owned aggregate
 * behind the test API so the journey cannot pass on SSR sentinels alone.
 */
export const actionJourneyIds = Object.freeze({
  proposalId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  assignmentId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  handoffId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
  executionId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
});
export const actionJourneyDigests = Object.freeze({
  content: "1".repeat(64),
  approval: "2".repeat(64),
  binding: "3".repeat(64),
  receipt: "4".repeat(64),
});
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
  providerControlProposals: new Map<string, ProviderControlProposal>(),
  providerControlEvents: [] as Array<{
    operationId: string;
    providerOperationId: ProviderControlOperationId;
    proposalId: string;
    state: ProviderControlProposal["state"];
  }>,
  directProviderCommandAttempts: [] as Array<{
    operationId: ProviderControlOperationId;
    bodySha256: string;
  }>,
  actionJourney: {
    proposalState: "PENDING_QUORUM" as
      | "PENDING_QUORUM"
      | "APPROVED"
      | "REJECTED",
    decision: null as "APPROVE" | "REJECT" | null,
    handoffState: "PENDING_ACK" as "PENDING_ACK" | "ACKNOWLEDGED" | "DECLINED",
    handoffVersion: 1,
    executionId: null as string | null,
    events: [] as Array<{
      operationId: string;
      before: string;
      after: string;
      proposalId: string;
      digest: string;
    }>,
  },
};

function resetAll() {
  runtime.loginTransactions.clear();
  runtime.stepUpTransactions.clear();
  runtime.activeSession = token(`internal-session-${randomUUID()}`);
  runtime.currentCsrf = token(`csrf-${randomUUID()}`);
  runtime.sessionRevoked = false;
  runtime.consumedOneTimeTokens.clear();
  runtime.exchangeReplays.clear();
  runtime.providerControlProposals.clear();
  runtime.providerControlEvents = [];
  runtime.actionJourney.proposalState = "PENDING_QUORUM";
  runtime.actionJourney.decision = null;
  runtime.actionJourney.handoffState = "PENDING_ACK";
  runtime.actionJourney.handoffVersion = 1;
  runtime.actionJourney.executionId = null;
  runtime.actionJourney.events = [];
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
  runtime.directProviderCommandAttempts = [];
}
function actor() {
  return {
    userId: "00000000-0000-4000-8000-000000000001",
    email: "e2e-reviewer@example.test",
    displayName: "E2E 검토자",
    roleCodes: ["administrator", "publisher"],
    capabilities: [
      "publication.publish",
      "publication.preview",
      "publication.correct",
      "cases.investigate",
      "cases.assign",
      "signals.triage",
      "evidence.create",
      "evidence.verify",
      "claims.author",
      "responses.review",
      "responses.request",
      "review.editorial",
      "sources.operate",
      "rules.propose",
      "rules.activate",
      "jobs.operate",
      "budgets.manage",
      "kill_switch.execute",
      "admin.users.manage",
      "admin.roles.manage",
      "audit.export",
      "audit.read",
      "roles.grant",
      "actions.read",
      "actions.propose",
      "actions.review",
      "actions.operate",
      "journeys.handoff.decide",
    ],
  };
}
function problem(status: number, code: string, title = code) {
  return Response.json(
    { type: "about:blank", title, status, requestId: randomUUID(), code },
    { status, headers: { "content-type": "application/problem+json" } },
  );
}
function addendumProblem(status: number, code: string, title = code) {
  return Response.json(
    { code, title, status, requestId: randomUUID() },
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
    providerControl: {
      proposals: [...runtime.providerControlProposals.values()],
      events: [...runtime.providerControlEvents],
      directCommandAttempts: [...runtime.directProviderCommandAttempts],
    },
    actionJourney: {
      ...runtime.actionJourney,
      events: [...runtime.actionJourney.events],
    },
  };
}
export {
  actor,
  addendumProblem,
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
