import {
  actionExecutionReceipt,
  actionProposalDetail,
  actionQueueResponse,
} from "./mock-api-action-reads";
import { handleExchange } from "./mock-api-exchange";
import {
  actionJourneyIds,
  asserted,
  attachmentStatus,
  expiresAt,
  problem,
  runtime,
  sha256,
} from "./mock-api-state";

export async function handleReadRoutes(
  request: Request,
  url: URL,
): Promise<Response> {
  const exchangeResponse = await handleExchange(request, url);
  if (exchangeResponse) return exchangeResponse;

  const submissionReadPaths = new Set([
    "/v1/response-session/access-status",
    "/v1/response-session",
    "/v1/response-session/draft",
    "/v1/response-session/download",
    "/v1/response-session/preview",
    "/v1/response-receipt",
    "/v1/correction-session",
    "/v1/correction-session/preview",
    "/v1/correction-receipt",
    "/v1/subscription-session",
  ]);
  if (request.method === "GET" && submissionReadPaths.has(url.pathname)) {
    if (!asserted(request)) return problem(401, "SERVICE_ASSERTION_REQUIRED");
    const sessionToken =
      request.headers.get("x-gurine-submission-session") ?? "";
    if (!sessionToken) return problem(401, "SUBMISSION_SESSION_REQUIRED");
    runtime.submissionReads.push({
      path: url.pathname,
      sessionTokenSha256: sha256(sessionToken),
    });
    if (url.pathname === "/v1/response-session/download") {
      return Response.json({
        binary: btoa(
          JSON.stringify({
            requestId: "77777777-7777-4777-8777-777777777777",
            status: "READY",
          }),
        ),
      });
    }
    if (url.pathname === "/v1/response-session/draft") {
      const attachments = [...runtime.attachmentUploads.values()]
        .filter(
          (item) =>
            item.kind === "response" &&
            item.sessionTokenSha256 === sha256(sessionToken),
        )
        .map(attachmentStatus);
      return Response.json({
        requestId: "77777777-7777-4777-8777-777777777777",
        version: runtime.responseDraftVersion,
        answers: [],
        attachments,
        publicationConsent: {
          body: false,
          attachments: [],
          redactionAcknowledged: false,
          scopeExplanation: "아직 공개 동의를 확정하지 않았습니다.",
          updatedAt: new Date().toISOString(),
        },
        savedAt: new Date().toISOString(),
        expiresAt: expiresAt(),
      });
    }
    if (url.pathname === "/v1/response-session/preview") {
      return Response.json({
        request: {
          requestId: "77777777-7777-4777-8777-777777777777",
          casePublicTitle: "E2E 공개 사건",
          partyName: "E2E 응답 기관",
          status: "OPEN",
          dueAt: expiresAt(),
          questionCount: 1,
        },
        answers: [],
        attachments: [],
        publicationConsent: {
          body: true,
          attachments: [],
          redactionAcknowledged: true,
          scopeExplanation: "본문 공개에 동의합니다.",
          updatedAt: new Date().toISOString(),
        },
        warnings: [],
        submissionDigest: "b".repeat(64),
      });
    }
    if (url.pathname === "/v1/correction-session") {
      return Response.json({
        id: "88888888-8888-4888-8888-888888888888",
        version: runtime.correctionDraftVersion,
        requesterType: "CITIZEN",
        contactEmail: "requester@example.test",
        summary: "공개 문장의 수치를 바로잡아 주세요.",
        requestedChanges: ["계약 금액을 원문과 일치시켜 주세요."],
        evidenceDescription: "공개 원문 링크를 확인했습니다.",
      });
    }
    if (url.pathname === "/v1/correction-session/preview") {
      const attachments = [...runtime.attachmentUploads.values()]
        .filter(
          (item) =>
            item.kind === "correction" &&
            item.sessionTokenSha256 === sha256(sessionToken),
        )
        .map(attachmentStatus);
      return Response.json({
        draft: {
          id: "88888888-8888-4888-8888-888888888888",
          version: runtime.correctionDraftVersion,
        },
        attachments,
        warnings: [],
        submissionDigest: "a".repeat(64),
      });
    }
    return Response.json({
      id: "77777777-7777-4777-8777-777777777777",
      status: "READY",
      version: 1,
      items: [],
      links: [],
    });
  }

  if (request.method === "GET") {
    // CAS-010/011 use the same typed authority envelopes as production.  Keep
    // these fixtures rich enough to exercise the authenticated
    // API -> projection -> rendered visualization/provenance path; the
    // generic empty-page fallback below intentionally must not be used for
    // these routes.
    const casCaseId = "80000000-0000-4000-8000-000000000001";
    const casRunId = "80000000-0000-4000-8000-000000000001";
    const casMetric = {
      kind: "METRIC",
      visualizationId: "run-count",
      title: "Agent 실행",
      value: 1,
      formattedValue: "1건",
      narrativeAlternative: "현재 케이스에 연결된 실행만 집계했습니다.",
      tableAlternative: {
        caption: "Agent 실행",
        headers: ["항목", "값"],
        rows: [["실행 건수", "1건"]],
        dataSha256: "a".repeat(64),
      },
    };
    const cas010Vm = {
      schemaVersion: "analysis-vm.cas-010.v2",
      screenId: "CAS-010",
      screenState: "saved",
      caseId: casCaseId,
      runs: [
        {
          runId: casRunId,
          agentTypeLabel: "문서 분석 Agent",
          objective: "공개 원문과 계약 금액의 차이를 확인합니다.",
          status: "SUCCEEDED",
          statusLabel: "완료",
          controlState: "TERMINAL",
          sourceCount: 2,
          proposalSummary: { pending: 1, accepted: 0, rejected: 0, expired: 0 },
          costMicrosKrw: 120000,
          currency: "KRW",
          href: `/internal/cases/${casCaseId}/agent-runs/${casRunId}`,
        },
      ],
      filters: {
        agentTypes: [],
        statuses: [],
        proposalStates: [],
        sort: "NEWEST",
      },
      suggestions: [{ pending: 1, accepted: 0, rejected: 0, expired: 0 }],
      budget: {
        periodLabel: "현재 케이스",
        state: "AVAILABLE",
        costLedgerState: "AVAILABLE",
        values: {
          limitMicrosKrw: 1000000,
          reservedMicrosKrw: 880000,
          settledMicrosKrw: 120000,
          remainingMicrosKrw: 880000,
        },
      },
      visualizations: {
        visualizations: [casMetric],
        visualizationSetSha256: "b".repeat(64),
      },
      viewModelSha256: "c".repeat(64),
    };
    if (url.pathname.endsWith("/list-case-agent-runs")) {
      return Response.json({
        caseId: casCaseId,
        items: cas010Vm.runs,
        appliedFilters: cas010Vm.filters,
        analysisVm: cas010Vm,
        nextCursor: null,
      });
    }
    if (url.pathname.endsWith("/get-agent-run")) {
      const cas011Vm = {
        schemaVersion: "analysis-vm.cas-011.v2",
        screenId: "CAS-011",
        screenState: "completed",
        caseId: casCaseId,
        runId: casRunId,
        identity: {
          agentTypeLabel: "문서 분석 Agent",
          objective: "공개 원문과 계약 금액의 차이를 확인합니다.",
          status: "SUCCEEDED",
          statusLabel: "완료",
          version: 1,
          snapshotAsOf: "2026-07-19T00:00:00Z",
        },
        inputs: [{ sourceId: "source-1", locator: "원문 p.2", revision: 3 }],
        model: {
          provider: "fixture",
          model: "analysis-test",
          promptVersion: "v1",
        },
        output: {
          summary: "차이를 검토할 출발점이 확인되었습니다.",
          validationState: "VALIDATED",
        },
        citations: [
          { sourceId: "source-1", locator: "원문 p.2", label: "계약 금액" },
        ],
        safety: {
          promptInjectionState: "NOT_RUN",
          personalDataState: "NOT_RUN",
          rightsState: "UNKNOWN",
          classificationState: "LOCAL_ONLY",
          blockedReasons: [],
        },
        decisions: [
          {
            suggestionId: "suggestion-1",
            state: "PENDING",
            reason: "사람 확인 필요",
          },
        ],
        cost: {
          currency: "KRW",
          limitMicrosKrw: 1000000,
          reservedMicrosKrw: null,
          settledMicrosKrw: 120000,
          remainingMicrosKrw: 880000,
          state: "SETTLED",
          unknownReason: null,
          isEstimate: false,
        },
        visualizations: {
          visualizations: [casMetric],
          visualizationSetSha256: "b".repeat(64),
        },
        provenanceGraph: {
          graphSha256: "d".repeat(64),
          accessibleRowsSha256: "e".repeat(64),
          accessibleRows: [
            {
              ordinal: 0,
              fromLabel: "문서 분석 Agent",
              relationLabel: "생성",
              toLabel: "검증 결과",
              sourceHref:
                "/internal/cases/80000000-0000-4000-8000-000000000001/evidence",
              factSha256: "f".repeat(64),
            },
          ],
        },
        viewModelSha256: "g".repeat(64),
      };
      return Response.json({
        id: casRunId,
        caseId: casCaseId,
        status: "SUCCEEDED",
        analysisVm: cas011Vm,
        data: { analysisVm: cas011Vm },
      });
    }
    if (url.pathname === "/v1/content/funding") {
      const updatedAt = "2026-07-19T00:00:00Z";
      return Response.json({
        id: { id: "funding", status: "PUBLISHED", version: 1 },
        version: 1,
        status: "PUBLISHED",
        updatedAt,
        title: "재원 공개",
        summary:
          "재원·비용·이해상충 공개 상태와 편집 독립성 guardrail을 확인합니다.",
        data: {
          version: "1.0",
          title: "재원 공개",
          updatedAt,
          sections: [
            {
              id: "principles",
              heading: "독립성 원칙",
              body: "후원자와 편집의 방화벽을 유지합니다.",
              links: [],
            },
            {
              id: "income",
              heading: "재원",
              body: "서명된 disclosure가 없어 금액대는 UNKNOWN입니다.",
              links: [],
            },
            {
              id: "expenses",
              heading: "비용",
              body: "인프라·법률 검토 비용은 UNKNOWN입니다.",
              links: [],
            },
            {
              id: "donors",
              heading: "공개 기준",
              body: "집중도 threshold와 독립 검토 기준을 적용합니다.",
              links: [],
            },
            {
              id: "conflicts",
              heading: "이해상충",
              body: "회피·독립 검토·공개 범위를 기록합니다.",
              links: [],
            },
            {
              id: "reports",
              heading: "보고서",
              body: "기간별 transparency report를 확인할 수 있습니다.",
              links: [],
            },
          ],
          sourceLinks: [],
        },
        links: [{ rel: "reports", href: "/transparency-reports" }],
      });
    }
    if (url.pathname === "/v1/transparency-reports") {
      return Response.json({
        items: [],
        nextCursor: null,
        asOf: "2026-07-19T00:00:00Z",
      });
    }
    if (url.pathname === "/v1/contracts/download") {
      return Response.json({
        id: "contracts-e2e-export",
        status: "READY",
        version: 1,
      });
    }
    if (url.pathname === "/v1/cases/synthetic-record") {
      return Response.json({
        slug: "synthetic-record",
        title: "공개 사례 테스트",
        publicState: "PUBLISHED_ANOMALY",
        revision: 3,
        publishedAt: "2026-07-12T00:00:00Z",
        updatedAt: "2026-07-13T00:00:00Z",
        summary: "원문에 연결된 확인 사실 요약입니다.",
        confirmedFacts: [
          { id: "fact-1", text: "계약 금액이 공개 원문과 일치합니다." },
        ],
        criticalUnknowns: [
          {
            id: "unknown-1",
            text: "추가 당사자 자료는 아직 확인되지 않았습니다.",
          },
        ],
        partyResponses: [
          {
            party: "공급기관",
            status: "RECEIVED",
            submittedAt: "2026-07-12T12:00:00Z",
          },
        ],
        signals: [{ id: "signal-1", state: "OPEN", label: "반복 계약" }],
        comparison: {
          cohort: "동일 기관·동일 기간",
          exclusions: [],
          distribution: "중앙값 기준",
        },
        counterEvidence: [
          { id: "counter-1", text: "대안 설명 자료가 검토되었습니다." },
        ],
        claims: [{ id: "claim-1", text: "핵심 주장", status: "SUPPORTED" }],
        evidence: [
          {
            id: "evidence-1",
            locator: "원문 p.2",
            validationStatus: "VALIDATED",
          },
        ],
        timeline: [
          {
            id: "event-1",
            label: "공개 revision 3",
            at: "2026-07-13T00:00:00Z",
          },
        ],
        corrections: [],
        freshness: { status: "CURRENT", asOf: "2026-07-13T00:00:00Z" },
        limitations: ["공개자료에 포함된 범위만 검토합니다."],
        seo: {
          title: "공개 사례 테스트",
          description: "테스트",
          canonicalUrl: "/cases/synthetic-record",
          robots: "index,follow",
        },
      });
    }
    if (url.pathname === "/v1/internal/action-proposals") {
      return Response.json(actionQueueResponse());
    }
    if (url.pathname.startsWith("/v1/internal/action-proposals/")) {
      const proposalId = url.pathname.split("/").at(-1);
      if (proposalId !== actionJourneyIds.proposalId)
        return problem(404, "RESOURCE_NOT_FOUND");
      return Response.json(actionProposalDetail());
    }
    if (
      url.pathname.startsWith("/v1/internal/action-executions/") &&
      url.pathname.endsWith("/receipt")
    ) {
      const executionId = url.pathname.split("/").at(-2);
      if (executionId !== runtime.actionJourney.executionId)
        return problem(404, "RESOURCE_NOT_FOUND");
      return Response.json(actionExecutionReceipt());
    }
    if (url.pathname === "/v1/internal/queries/get-publish-confirmation") {
      return Response.json({
        id: "00000000-0000-4000-8000-000000000020",
        status: "ready",
        data: {
          caseId: "00000000-0000-4000-8000-000000000010",
          snapshotId: "00000000-0000-4000-8000-000000000020",
          previewHash: "b".repeat(64),
          currentCaseVersion: 1,
          requiredReauth: true,
          impactSummary: ["공개 projection과 알림이 갱신됩니다."],
          publicUrls: ["/cases/e2e-case"],
        },
        links: [],
      });
    }
    return Response.json({
      items: [],
      appliedFilters: Object.fromEntries(url.searchParams),
      asOf: "2026-07-12T00:00:00Z",
      nextCursor: null,
    });
  }
  return problem(409, "SYNTHETIC_READ_ONLY", "Synthetic mutation disabled");
}
