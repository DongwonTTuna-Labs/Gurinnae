import { describe, expect, it } from "vitest";
import { ROUTE_SCREEN_CONTRACTS } from "./generated-screen-contracts";
import type { ScreenViewModel } from "./index";
import { projectFetchedData, projectScreen } from "./screen-projection";

function screen(id: string): ScreenViewModel {
  const contract =
    ROUTE_SCREEN_CONTRACTS[id as keyof typeof ROUTE_SCREEN_CONTRACTS];
  if (!contract) throw new Error(`unknown test screen: ${id}`);
  return {
    id,
    title: contract.objectLabel,
    route: "/test",
    archetype: "WORKSPACE",
    sections: contract.sections.map((section) => ({
      id: section.id,
      title: section.id,
      purpose: "현재 상태와 다음 행동을 확인합니다.",
      component: section.component ?? "StructuredContentSection",
      test_id: section.testId,
    })),
    actions: [],
    states: ["success"],
    dataOperations: [
      {
        operation_id: "internalQuery",
        method: "GET",
        path: "/v1/query",
        blocking: true,
      },
    ],
  };
}
describe("closed CAS screen projection", () => {
  it("does not collapse nested agent payloads into count-only browser fields", () => {
    const current = screen("CAS-011");
    const runtime = {
      state: "success" as const,
      data: {
        getAgentRun: { proposals: [{ id: "proposal-1", status: "READY" }] },
      },
      errors: [],
      forms: {},
      pathname: "/internal/cases/1/agent-runs/2",
    };
    const projection = projectScreen(current, {
      ...runtime,
      data: {},
      projection: projectFetchedData(current, runtime.data),
    });
    const fields = Object.values(projection.sections).flatMap(
      (section) => section.fields,
    );
    expect(fields.some((field) => field.value === 1)).toBe(false);
    expect(fields.some((field) => field.known === false)).toBe(true);
  });
  it("binds the reduced CAS-010 envelope to the runs screen and keeps table metadata", () => {
    const current = screen("CAS-010");
    const runtime = {
      state: "success" as const,
      data: {
        listCaseAgentRuns: {
          items: [{ id: "run-1" }],
          analysisVm: {
            schemaVersion: "analysis-vm.cas-010.v2",
            screenId: "CAS-010",
            caseId: "case-1",
            screenState: "saved",
            filters: { sort: "NEWEST" },
            runs: [{ runId: "run-1" }],
            suggestions: [{ id: "suggestion-1" }],
            budget: {
              state: "BLOCKED",
              unknownReason: "COST_LEDGER_UNAVAILABLE",
            },
            visualizations: {
              visualizations: [
                {
                  visualizationId: "run-count",
                  kind: "METRIC",
                  title: "Agent 실행",
                  value: 1,
                  formattedValue: "1",
                  narrativeAlternative:
                    "현재 케이스에 연결된 실행만 집계했습니다.",
                  tableAlternative: {
                    caption: "Agent 실행",
                    headers: ["항목", "값"],
                    rows: [["run-count", "1"]],
                    dataSha256: "a".repeat(64),
                  },
                },
              ],
              visualizationSetSha256: "b".repeat(64),
            },
            viewModelSha256: "c".repeat(64),
          },
        },
      },
      errors: [],
      forms: {},
      pathname: "/internal/cases/1/agent-runs",
    };
    const projection = projectScreen(current, {
      ...runtime,
      data: {},
      projection: projectFetchedData(current, runtime.data),
    });
    expect(
      projection.sections.runs?.analysis?.visualizations[0]
        ?.narrativeAlternative,
    ).toContain("집계");
    expect(
      projection.sections.runs?.analysis?.visualizations[0]?.tableAlternative
        .rows[0],
    ).toEqual(["run-count", "1"]);
    expect(projection.sections.runs?.state).toBe("PARTIAL");
    expect(
      projection.sections.filters?.fields.find(
        (field) => field.name === "filters",
      )?.known,
    ).toBe(true);
    expect(
      projection.sections.budget?.fields.find(
        (field) => field.name === "budget",
      )?.value,
    ).toContain("BLOCKED");
    const runtimeProjection = projectFetchedData(current, {
      listCaseAgentRuns: {
        items: [{ id: "run-1" }],
        analysisVm: {
          schemaVersion: "analysis-vm.cas-010.v2",
          screenId: "CAS-010",
          visualizations: {
            visualizations: [
              {
                visualizationId: "run-count",
                kind: "METRIC",
                title: "Agent 실행",
                formattedValue: "1",
                narrativeAlternative: "한 건",
                tableAlternative: {
                  caption: "Agent 실행",
                  headers: ["항목"],
                  rows: [["1"]],
                  dataSha256: "a".repeat(64),
                },
              },
            ],
            visualizationSetSha256: "b".repeat(64),
          },
          viewModelSha256: "c".repeat(64),
        },
      },
    });
    expect(
      runtimeProjection.sections.runs?.analysis?.visualizations,
    ).toHaveLength(1);
  });
  it("unwraps CAS-011 data.analysisVm and projects an accessible provenance row", () => {
    const current = screen("CAS-011");
    const runtime = {
      state: "success" as const,
      data: {
        getAgentRun: {
          id: "run-1",
          data: {
            analysisVm: {
              schemaVersion: "analysis-vm.cas-011.v2",
              screenId: "CAS-011",
              caseId: "case-1",
              runId: "run-1",
              screenState: "saved",
              identity: { agentTypeLabel: "Agent" },
              inputs: [{ sourceUseId: "source-1" }],
              model: { providerLabel: "deterministic" },
              output: { status: "COMPLETED" },
              citations: [{ citationId: "citation-1" }],
              safety: { rightsState: "UNKNOWN" },
              decisions: [{ proposalId: "proposal-1" }],
              cost: { state: "RECONCILIATION_REQUIRED" },
              visualizations: {
                visualizations: [],
                visualizationSetSha256: "b".repeat(64),
              },
              provenanceGraph: {
                graphSha256: "d".repeat(64),
                accessibleRowsSha256: "e".repeat(64),
                accessibleRows: [
                  {
                    ordinal: 0,
                    fromLabel: "Agent",
                    relationLabel: "생성",
                    toLabel: "결과",
                    sourceHref: "/internal/source/1",
                    factSha256: "f".repeat(64),
                  },
                ],
              },
              viewModelSha256: "c".repeat(64),
            },
          },
        },
      },
      errors: [],
      forms: {},
      pathname: "/internal/cases/1/agent-runs/run-1",
    };
    const projection = projectScreen(current, {
      ...runtime,
      data: {},
      projection: projectFetchedData(current, runtime.data),
    });
    expect(
      projection.sections.inputs?.fields.find(
        (field) => field.name === "inputs",
      )?.value,
    ).toBe(1);
    expect(
      projection.sections.inputs?.analysis?.provenanceRows[0]?.relationLabel,
    ).toBe("생성");
    expect(projection.sections.inputs?.analysis?.provenanceRows).toHaveLength(
      1,
    );
    expect(
      projection.sections.identity?.fields.find(
        (field) => field.name === "identity",
      )?.known,
    ).toBe(true);
    expect(
      projection.sections.model?.fields.find((field) => field.name === "model")
        ?.known,
    ).toBe(true);
    expect(
      projection.sections.cost?.fields.find((field) => field.name === "cost")
        ?.value,
    ).toContain("RECONCILIATION_REQUIRED");
  });
  it("maps live list/detail envelopes into every CAS section", () => {
    const metric = {
      visualizationId: "run-count",
      kind: "METRIC",
      title: "Agent 실행",
      value: 1,
      formattedValue: "1",
      narrativeAlternative: "현재 실행 한 건",
      tableAlternative: {
        caption: "Agent 실행",
        headers: ["항목", "값"],
        rows: [["run-count", "1"]],
        dataSha256: "a".repeat(64),
      },
    };
    const listRuntime = {
      state: "success" as const,
      data: {
        listCaseAgentRuns: {
          items: [
            {
              id: "run-1",
              caseId: "case-1",
              agentType: "investigator",
              status: "SUCCEEDED",
              objective: "검증",
              maxCost: "100",
              actualCost: "20",
              suggestionCounts: { pending: 1 },
              sourceUseCount: 1,
            },
          ],
          appliedFilters: { caseId: "case-1" },
          asOf: "2026-07-19T00:00:00Z",
          analysisVm: {
            schemaVersion: "analysis-vm.cas-010.v2",
            screenId: "CAS-010",
            screenState: "saved",
            caseId: "case-1",
            runs: [
              {
                runId: "run-1",
                agentTypeLabel: "investigator",
                objective: "검증",
                status: "SUCCEEDED",
                statusLabel: "완료",
                costMicrosKrw: 20,
              },
            ],
            filters: { caseId: "case-1" },
            suggestions: [{ id: "proposal-1", status: "PENDING" }],
            budget: null,
            visualizations: {
              visualizations: [metric],
              visualizationSetSha256: "b".repeat(64),
            },
            viewModelSha256: "c".repeat(64),
          },
        },
      },
      errors: [],
      forms: {},
      pathname: "/internal/cases/case-1/agent-runs",
    };
    const listProjection = projectScreen(screen("CAS-010"), {
      ...listRuntime,
      data: {},
      projection: projectFetchedData(screen("CAS-010"), listRuntime.data),
    });
    for (const section of ["runs", "filters", "suggestions"]) {
      expect(
        listProjection.sections[section]?.fields.some((field) => field.known),
      ).toBe(true);
    }
    expect(listProjection.sections.budget?.state).toBe("UNKNOWN");
    expect(listProjection.sections.runs?.analysis?.visualizations).toHaveLength(
      1,
    );

    const detailRuntime = {
      state: "success" as const,
      data: {
        getAgentRun: {
          id: "run-1",
          status: "SUCCEEDED",
          data: {
            id: "run-1",
            caseId: "case-1",
            agentType: "investigator",
            objective: "검증",
            status: "SUCCEEDED",
            sourceUses: [
              {
                id: "source-1",
                sourceKind: "EVIDENCE_SEGMENT",
                locatorValue: "p.1",
              },
            ],
            provider: "double",
            model: "deterministic",
            maxCost: "100",
            actualCost: "20",
            safetyFlags: ["NONE"],
            providerTurns: [
              {
                id: "turn-1",
                provider: "double",
                model: "deterministic",
                status: "COMPLETED",
              },
            ],
            validation: [
              { id: "validation-1", status: "PASS", schemaStatus: "PASS" },
            ],
            citations: [
              {
                id: "citation-1",
                sourceKind: "EVIDENCE_SEGMENT",
                locatorValue: "p.1",
                supports: "검증",
              },
            ],
            suggestions: [{ id: "proposal-1", status: "PENDING" }],
            output: { answerFirstSummary: "검증 결과" },
            analysisVm: {
              schemaVersion: "analysis-vm.cas-011.v2",
              screenId: "CAS-011",
              caseId: "case-1",
              runId: "run-1",
              identity: {
                agentTypeLabel: "investigator",
                objective: "검증",
                statusLabel: "완료",
              },
              inputs: [
                {
                  sourceUseId: "source-1",
                  sourceKind: "EVIDENCE_SEGMENT",
                  locatorLabel: "p.1",
                },
              ],
              model: {
                providerLabel: "double",
                modelLabel: "deterministic",
                receiptState: "COMPLETE",
              },
              output: {
                status: "COMPLETED",
                answerFirstSummary: "검증 결과",
                hypotheses: [
                  {
                    label: "계약 시점이 비정상적으로 근접함",
                    confidenceLabel: "중간",
                  },
                ],
                counterEvidence: [
                  {
                    label: "공개된 변경 공고가 존재함",
                    supports: "정상 변경 가능성",
                  },
                ],
                unknowns: [
                  {
                    label: "원계약 변경 사유",
                    impact: "가설 판별에 필요",
                  },
                ],
                investigationsPerformed: [
                  {
                    label: "공고·계약 리비전 대조",
                    outcome: "시점 차이 확인",
                  },
                ],
                nextActions: [
                  {
                    label: "담당자에게 변경 사유 확인",
                    reason: "미확인 사항 해소",
                  },
                ],
                validation: {
                  schema: "PASS",
                  citations: "PASS",
                  rights: "PASS",
                  policy: "PASS",
                  failureLabel: null,
                  validationSha256: null,
                },
              },
              safety: {
                promptInjectionState: "CLEAR",
                personalDataState: "CLEAR",
                rightsState: "ALLOWED",
                classificationState: "LOCAL_ONLY",
                blockedReasons: [],
              },
              cost: {
                state: "RECONCILIATION_REQUIRED",
                unknownReason: "COST_LEDGER_UNAVAILABLE",
              },
              visualizations: {
                visualizations: [metric],
                visualizationSetSha256: "b".repeat(64),
              },
              provenanceGraph: {
                graphSha256: "d".repeat(64),
                accessibleRowsSha256: "e".repeat(64),
                accessibleRows: [
                  {
                    ordinal: 0,
                    fromLabel: "Agent",
                    relationLabel: "생성",
                    toLabel: "결과",
                    factSha256: "f".repeat(64),
                  },
                ],
              },
              viewModelSha256: "c".repeat(64),
            },
          },
        },
      },
      errors: [],
      forms: {},
      pathname: "/internal/cases/case-1/agent-runs/run-1",
    };
    const detailProjection = projectScreen(screen("CAS-011"), {
      ...detailRuntime,
      data: {},
      projection: projectFetchedData(screen("CAS-011"), detailRuntime.data),
    });
    for (const section of [
      "identity",
      "inputs",
      "model",
      "output",
      "citations",
      "safety",
      "decisions",
      "cost",
    ]) {
      expect(
        detailProjection.sections[section]?.fields.some((field) => field.known),
      ).toBe(true);
    }
    expect(
      detailProjection.sections.inputs?.analysis?.provenanceRows,
    ).toHaveLength(1);
    const outputFields = JSON.stringify(
      detailProjection.sections.output?.fields ?? [],
    );
    expect(outputFields).toContain("계약 시점이 비정상적으로 근접함");
    expect(outputFields).toContain("공개된 변경 공고가 존재함");
    expect(outputFields).toContain("원계약 변경 사유");
    expect(outputFields).toContain("공고·계약 리비전 대조");
    expect(outputFields).toContain("담당자에게 변경 사유 확인");
  });
});
