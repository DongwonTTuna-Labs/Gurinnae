import { describe, expect, test } from "vitest";
import { toCas010ViewModel } from "./cas-010";
import { toCas011ViewModel } from "./cas-011";

const metric = {
  visualizationId: "run-count",
  kind: "METRIC",
  title: "Agent 실행",
  value: 1,
  formattedValue: "1",
  narrativeAlternative: "한 건",
  tableAlternative: {
    caption: "Agent 실행",
    headers: ["항목", "값"],
    rows: [["run-count", "1"]],
    dataSha256: "a".repeat(64),
  },
};

describe("CAS authority view models", () => {
  test("keeps CAS-010 visualization digest and run rows typed", () => {
    const vm = toCas010ViewModel({
      listCaseAgentRuns: {
        analysisVm: {
          schemaVersion: "analysis-vm.cas-010.v2",
          screenId: "CAS-010",
          caseId: "00000000-0000-0000-0000-000000000001",
          screenState: "saved",
          runs: [{ runId: "00000000-0000-0000-0000-000000000002" }],
          visualizations: {
            visualizations: [metric],
            visualizationSetSha256: "b".repeat(64),
          },
          viewModelSha256: "c".repeat(64),
        },
      },
    });
    expect(vm?.visualizations[0]?.visualizationId).toBe("run-count");
    expect(vm?.runs).toHaveLength(1);
    expect(vm?.visualizationSetSha256).toBe("b".repeat(64));
  });

  test("unwraps reduced CAS-010 operation data envelopes", () => {
    const vm = toCas010ViewModel({
      listCaseAgentRuns: {
        data: {
          items: [{ runId: "run-1" }],
          analysisVm: {
            schemaVersion: "analysis-vm.cas-010.v2",
            screenId: "CAS-010",
            visualizations: {
              visualizations: [metric],
              visualizationSetSha256: "b".repeat(64),
            },
            viewModelSha256: "c".repeat(64),
          },
        },
      },
    });
    expect(vm?.visualizations).toHaveLength(1);
    expect(vm?.runs).toHaveLength(1);
  });

  test("maps the closed authority CaseAgentRunsPage without analysisVm", () => {
    const vm = toCas010ViewModel({
      listCaseAgentRuns: {
        data: {
          items: [{ id: "run-1", status: "SUCCEEDED", objective: "확인" }],
          appliedFilters: { statuses: ["SUCCEEDED"] },
          asOf: "2026-07-20T00:00:00Z",
        },
      },
    });
    expect(vm?.screenState).toBe("saved");
    expect(vm?.runs[0]?.id).toBe("run-1");
    expect(vm?.visualizations).toHaveLength(0);
  });

  test("exposes CAS-011 accessible provenance facts", () => {
    const vm = toCas011ViewModel({
      getAgentRun: {
        analysisVm: {
          schemaVersion: "analysis-vm.cas-011.v2",
          screenId: "CAS-011",
          caseId: "00000000-0000-0000-0000-000000000001",
          runId: "00000000-0000-0000-0000-000000000002",
          screenState: "saved",
          identity: {},
          output: {},
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
    });
    expect(vm?.provenanceRows[0]?.relationLabel).toBe("생성");
    expect(vm?.graphSha256).toBe("d".repeat(64));
    expect(vm?.accessibleRowsSha256).toBe("e".repeat(64));
  });

  test("maps the closed authority AgentRun without analysisVm", () => {
    const vm = toCas011ViewModel({
      getAgentRun: {
        data: {
          id: "run-1",
          caseId: "case-1",
          agentType: "investigator",
          objective: "확인",
          status: "SUCCEEDED",
          evidenceScopeIds: ["source-1"],
          citations: ["source-1"],
          unknowns: ["확인되지 않음"],
          output: "결과 요약",
          provider: "fixture",
          model: "test-model",
        },
      },
    });
    expect(vm?.screenState).toBe("SUCCEEDED");
    expect(vm?.inputs[0]?.sourceId).toBe("source-1");
    expect(vm?.output?.summary).toBe("결과 요약");
    expect(vm?.citations[0]?.sourceId).toBe("source-1");
  });
});
