import operationSamples from "../../../verification/generated-operation-samples.json";
import {
  actionExecutionReceipt,
  actionProposalDetail,
  actionQueueResponse,
} from "./mock-api-action-reads";
import { handleExchange } from "./mock-api-exchange";
import { mockOperationId } from "./mock-api-openapi";
import {
  publicDownloadRead,
  publicReadResponseBody,
} from "./mock-api-public-export-reads";
import { rowNavigationResponseBody } from "./mock-api-row-navigation";
import { actionJourneyIds, problem, runtime } from "./mock-api-state";
import { handleSubmissionRead } from "./mock-api-submission-reads";

type OperationSample = {
  body: unknown;
  mediaType: string;
  status: number;
};

const responseSamples = operationSamples as Record<string, OperationSample>;

export async function handleReadRoutes(
  request: Request,
  url: URL,
): Promise<Response> {
  const exchangeResponse = await handleExchange(request, url);
  if (exchangeResponse) return exchangeResponse;
  const submissionRead = await handleSubmissionRead(request, url);
  if (submissionRead) return submissionRead;

  if (request.method === "GET") {
    const publicDownload = publicDownloadRead(url);
    if (publicDownload) return publicDownload;
    if (url.pathname === "/v1/openapi.json") {
      return Response.json({
        id: "public-openapi-v1",
        status: "READY",
        version: 1,
        filename: "gurine-public-api.openapi.json",
        mediaType: "application/json",
      });
    }
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
      title: "에이전트 실행",
      value: 1,
      formattedValue: "1건",
      narrativeAlternative: "현재 케이스에 연결된 실행만 집계했습니다.",
      tableAlternative: {
        caption: "에이전트 실행",
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
          agentTypeLabel: "문서 분석 에이전트",
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
        analysisVm: cas010Vm,
        items: [
          {
            id: casRunId,
            agentType: "DOCUMENT_ANALYSIS",
            status: "SUCCEEDED",
            objective: "공개 원문과 계약 금액의 차이를 확인합니다.",
          },
        ],
        appliedFilters: { caseId: casCaseId, status: [], agentType: [] },
        asOf: "2026-07-19T00:00:00Z",
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
          agentTypeLabel: "문서 분석 에이전트",
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
              fromLabel: "문서 분석 에이전트",
              relationLabel: "생성",
              toLabel: "검증 결과",
              sourceHref:
                "/internal/cases/80000000-0000-4000-8000-000000000001/evidence",
              factSha256: "f".repeat(64),
            },
          ],
        },
        viewModelSha256: "f".repeat(64),
      };
      return Response.json({
        id: casRunId,
        status: "SUCCEEDED",
        data: {
          analysisVm: cas011Vm,
          id: casRunId,
          caseId: casCaseId,
          agentType: "DOCUMENT_ANALYSIS",
          objective: "공개 원문과 계약 금액의 차이를 확인합니다.",
          status: "SUCCEEDED",
          evidenceScopeIds: [],
          citations: [],
          unknowns: [],
        },
        links: [],
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
          "재원·비용·이해상충 공개 상태와 편집 독립성 기준을 확인합니다.",
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
              body: "서명된 공개 자료가 없어 금액대를 확인할 수 없습니다.",
              links: [],
            },
            {
              id: "expenses",
              heading: "비용",
              body: "인프라·법률 검토 비용은 아직 확인되지 않았습니다.",
              links: [],
            },
            {
              id: "donors",
              heading: "공개 기준",
              body: "후원 집중도 기준과 독립 검토 기준을 적용합니다.",
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
        appliedFilters: {
          periodFrom: url.searchParams.get("periodFrom") ?? undefined,
          periodTo: url.searchParams.get("periodTo") ?? undefined,
        },
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
      const sample = operationSamples.getPublicCase.body;
      return Response.json({
        ...sample,
        slug: "synthetic-record",
        title: "공개 사례 테스트",
        publicState: "PUBLISHED_ANOMALY",
        revision: 3,
        publishedAt: "2026-07-12T00:00:00Z",
        updatedAt: "2026-07-13T00:00:00Z",
        summary: "원문에 연결된 확인 사실 요약입니다.",
        agencyName: "가상해안시 도시정책국",
        contractName: "가상 해안도시 통합계약",
        amount: { amount: "1250000000", currency: "KRW" },
        nonConclusion: "이 기록은 이상 징후이며 위법·부패의 확정이 아닙니다.",
        confirmedFacts: [
          {
            id: "fact-1",
            statement: "계약 금액이 공개 원문과 일치합니다.",
            evidenceIds: ["80000000-0000-4000-8000-000000000001"],
            verifiedAt: "2026-07-13T00:00:00Z",
            scope: null,
          },
        ],
        criticalUnknowns: [
          {
            id: "unknown-1",
            question: "추가 당사자 자료는 확인되었습니까?",
            whyMaterial: "추가 자료가 결론의 적용 범위를 바꿀 수 있습니다.",
            nextAction: null,
            status: "OPEN",
          },
        ],
        partyResponses: [
          {
            id: "80000000-0000-4000-8000-000000000002",
            partyName: "공급기관",
            status: "RECEIVED",
            submittedAt: "2026-07-12T12:00:00Z",
            excerpt: null,
            attachmentCount: 0,
            publicationConsent: {
              body: true,
              attachments: [],
              redactionAcknowledged: true,
              scopeExplanation: "본문 공개에 동의했습니다.",
              updatedAt: "2026-07-12T12:00:00Z",
            },
          },
        ],
        signals: [
          {
            id: "80000000-0000-4000-8000-000000000003",
            ruleId: "repeat-contract",
            label: "반복 계약",
            explanation: "동일 당사자의 반복 계약을 확인합니다.",
            calculationSummary: "공개 원문 기준 집계",
            blockers: [],
          },
        ],
        comparison: {
          target: {
            id: "target-contract",
            contractId: "80000000-0000-4000-8000-000000000004",
            agencyName: "공급기관",
            supplierName: null,
            observedAt: "2026-07-12",
            quantity: "1",
            unit: "건",
            unitPrice: { amount: "1000000", currency: "KRW" },
            vatIncluded: null,
            bundleSummary: [],
            compatibility: "COMPARABLE",
            includeReason: "동일 기관·동일 기간",
          },
          result: {
            benchmarkType: "MEDIAN",
            benchmarkValue: { amount: "1000000", currency: "KRW" },
            targetValue: { amount: "1000000", currency: "KRW" },
            ratio: "1",
            includedCount: 1,
            excludedCount: 0,
            formula: "target / median",
            roundingPolicy: "NONE",
          },
          included: [],
          excluded: [],
          blockers: [],
          limitations: [],
        },
        counterEvidence: [
          {
            id: "80000000-0000-4000-8000-000000000005",
            title: "대안 설명 자료",
            evidenceType: "DOCUMENT",
            verificationStatus: "VALIDATED",
            supports: [],
            href: null,
          },
        ],
        claims: [
          {
            id: "80000000-0000-4000-8000-000000000006",
            claimType: "FACTUAL",
            text: "핵심 주장",
            evidenceIds: ["80000000-0000-4000-8000-000000000001"],
            responseIds: [],
            limitations: [],
          },
        ],
        evidence: [
          {
            id: "80000000-0000-4000-8000-000000000001",
            title: "원문 p.2",
            evidenceType: "DOCUMENT",
            documentTitle: "가상 해안도시 통합계약 공고문",
            publisher: "가상해안시 도시정책국",
            publishedAt: "2026-07-11T09:00:00Z",
            sourceUrl:
              "https://records.example.test/contracts/synthetic-record.pdf",
            pageAnchor: "#page=2",
            sourceLocator: "원문 p.2",
            contentSha256: "a".repeat(64),
            publicExcerpt: null,
            restriction: null,
          },
        ],
        timeline: [
          {
            id: "event-1",
            occurredAt: "2026-07-13T00:00:00Z",
            eventType: "REVISION_PUBLISHED",
            title: "공개 revision 3",
            description: null,
            actor: null,
            revision: 3,
          },
        ],
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
    const operationId = mockOperationId(request);
    const sample = operationId ? responseSamples[operationId] : undefined;
    if (!operationId || !sample)
      return problem(500, "MOCK_READ_RESPONSE_SAMPLE_MISSING");
    const body = rowNavigationResponseBody(operationId, sample.body, url);
    return new Response(
      JSON.stringify(publicReadResponseBody(operationId, body, url)),
      {
        status: sample.status,
        headers: { "content-type": sample.mediaType },
      },
    );
  }
  return problem(409, "SYNTHETIC_READ_ONLY", "Synthetic mutation disabled");
}
