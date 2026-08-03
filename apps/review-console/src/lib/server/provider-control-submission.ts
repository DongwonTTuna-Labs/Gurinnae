import type { RequestEvent } from "@sveltejs/kit";
import { requestContext } from "./actor-context";
import {
  buildProviderControlProposal,
  type ProviderControlOperationId,
} from "./provider-control-proposal";
import type { loadRelayModelMutationContext } from "./relay-model-action";
import { operations } from "./screen-contract";
import { controlRequest, identityCall } from "./screen-control";
import { problemTitle, sessionToken } from "./screen-helpers";

export type ProviderProposalSubmission =
  | { ok: true; proposalId: string }
  | { ok: false; status: number; message: string };

export async function submitProviderControlProposal(
  event: RequestEvent,
  operationId: ProviderControlOperationId,
  input: Record<string, unknown>,
  relay: Awaited<ReturnType<typeof loadRelayModelMutationContext>>,
  idempotencyKey: string,
): Promise<ProviderProposalSubmission> {
  if (!relay.ok || !relay.authority)
    return {
      ok: false,
      status: 409,
      message: "relay 공급자 최신 상태를 확인할 수 없습니다.",
    };
  const session = sessionToken(event);
  if (!session)
    return { ok: false, status: 401, message: "SESSION_NOT_ACTIVE" };
  const resolvedSession = await identityCall(
    event,
    "/internal/v1/sessions/resolve",
    { opaqueSessionToken: session, context: requestContext(event) },
  );
  if (!resolvedSession.response.ok)
    return {
      ok: false,
      status: resolvedSession.response.status,
      message: problemTitle(
        resolvedSession.value,
        resolvedSession.response.status,
      ),
    };
  const actor = asRecord(asRecord(resolvedSession.value)?.actor);
  const actorId = typeof actor?.userId === "string" ? actor.userId : "";
  const proposal = buildProviderControlProposal({
    operationId,
    input,
    authority: relay.authority,
    activeModelIds: relay.activeModelIds,
    actorId,
    now: new Date(),
  });
  if (!proposal.ok) return proposal;
  const indexed = operations.get(proposal.dispatch.operationId);
  if (!indexed)
    return {
      ok: false,
      status: 500,
      message: "작업 제안 생성 계약을 찾지 못했습니다.",
    };
  const result = await controlRequest(
    event,
    indexed,
    indexed.path,
    "",
    proposal.dispatch.body,
    idempotencyKey,
  );
  if (!result.response.ok)
    return {
      ok: false,
      status: result.response.status,
      message: problemTitle(result.value, result.response.status),
    };
  const proposalId = asRecord(asRecord(result.value)?.proposal)?.proposalId;
  if (typeof proposalId !== "string" || !proposalId.trim())
    return {
      ok: false,
      status: 502,
      message: "생성된 작업 제안 식별자가 응답에 없습니다.",
    };
  return { ok: true, proposalId };
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}
