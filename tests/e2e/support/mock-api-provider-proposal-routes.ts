import { actionQueueResponse } from "./mock-api-action-reads";
import { buildProviderPreview } from "./mock-api-provider-proposal-preview";
import {
  providerExecutionReceipt,
  providerProposalDetail,
  providerQueueResponse,
} from "./mock-api-provider-proposal-reads";
import { providerProposalByExecutionId } from "./mock-api-provider-proposal-state";
import {
  addendumProblem,
  type ProviderControlProposal,
  runtime,
} from "./mock-api-state";

function latestPreview(proposal: ProviderControlProposal) {
  if (!proposal.previewId || proposal.previewVersion === null) return null;
  return buildProviderPreview(
    { ...proposal, version: proposal.previewVersion },
    proposal.previewId,
  );
}

function combinedApprovalQueue(proposals: ProviderControlProposal[]) {
  const existing = actionQueueResponse();
  const provider = providerQueueResponse(proposals);
  return {
    ...existing,
    items: [...existing.items, ...provider.items],
    appliedFilters: {
      actionKind: [
        ...new Set([
          ...existing.appliedFilters.actionKind,
          ...provider.appliedFilters.actionKind,
        ]),
      ],
      proposalState: [
        ...new Set([
          ...existing.appliedFilters.proposalState,
          ...provider.appliedFilters.proposalState,
        ]),
      ],
      assignmentState: [
        ...new Set([
          ...existing.appliedFilters.assignmentState,
          ...provider.appliedFilters.assignmentState,
        ]),
      ],
      dueBefore: existing.appliedFilters.dueBefore,
      sort: "DUE_ASC",
    },
    asOf: new Date().toISOString(),
    nextCursor: "",
    totalApproximate: existing.totalApproximate + provider.totalApproximate,
  };
}

export async function handleProviderProposalReads(
  request: Request,
  url: URL,
): Promise<Response | undefined> {
  if (request.method !== "GET") return undefined;
  if (
    url.pathname === "/v1/internal/action-proposals" &&
    runtime.providerControlProposals.size > 0
  ) {
    return Response.json(
      combinedApprovalQueue([...runtime.providerControlProposals.values()]),
    );
  }
  const detailMatch = url.pathname.match(
    /^\/v1\/internal\/action-proposals\/([^/:]+)$/,
  );
  if (detailMatch) {
    const proposalId = detailMatch[1];
    if (!proposalId) return undefined;
    const proposal = runtime.providerControlProposals.get(proposalId);
    if (!proposal) return undefined;
    return Response.json(
      providerProposalDetail(proposal, latestPreview(proposal)),
    );
  }
  const receiptMatch = url.pathname.match(
    /^\/v1\/internal\/action-executions\/([^/:]+)\/receipt$/,
  );
  if (!receiptMatch) return undefined;
  const executionId = receiptMatch[1];
  if (!executionId) return undefined;
  const proposal = providerProposalByExecutionId(executionId);
  if (!proposal) return undefined;
  const receipt = providerExecutionReceipt(proposal);
  return receipt
    ? Response.json(receipt)
    : addendumProblem(409, "EXECUTION_RECEIPT_INCOMPLETE");
}
