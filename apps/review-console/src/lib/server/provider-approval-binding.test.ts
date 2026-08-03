import type { ScreenViewModel } from "@gurine/ui";
import { describe, expect, it } from "vitest";
import {
  bindProviderDecision,
  providerDecisionAssurance,
  providerOperationBinding,
  submittedProviderOperationBinding,
} from "./provider-control-approval";
import { PROVIDER_CONTROL_OPERATION_IDS } from "./provider-control-proposal";
import { formsFor } from "./screen-helpers";

const approvalScreen: ScreenViewModel = {
  id: "TEST-APPROVAL",
  title: "승인 테스트",
  route: "/test",
  archetype: "DECISION_REVIEW",
  sections: [],
  actions: [
    {
      id: "decide",
      label: "결정",
      operation_id: "submitActionDecision",
      capability: "actions.review",
      interaction_kind: "COMMAND",
      assurance_level: "conditional-by-action-and-decision",
      step_up_required: false,
      confirmation_required: false,
      expand_request_objects: ["decision"],
    },
  ],
  states: ["success", "conflict"],
  dataOperations: [],
};

function providerPayload(operationId: string): Record<string, unknown> {
  return {
    kind: "PROVIDER_CONTROL",
    providerControl: { operationId },
  };
}

describe("provider approval binding", () => {
  it.each(
    PROVIDER_CONTROL_OPERATION_IDS,
  )("binds %s only from the typed proposal payload", (operationId) => {
    expect(
      providerOperationBinding(
        "PROVIDER_CONTROL",
        providerPayload(operationId),
      ),
    ).toEqual({ valid: true, providerOperationId: operationId });
  });

  it("requires the submitted discriminator to equal the immutable detail", () => {
    const payload = providerPayload("upgradeProviderModel");
    expect(
      submittedProviderOperationBinding(
        "PROVIDER_CONTROL",
        payload,
        "upgradeProviderModel",
      ),
    ).toEqual({
      valid: true,
      providerOperationId: "upgradeProviderModel",
    });
    for (const submitted of [
      undefined,
      "testProviderConnection",
      "unknownProviderOperation",
    ]) {
      expect(
        submittedProviderOperationBinding(
          "PROVIDER_CONTROL",
          payload,
          submitted,
        ),
      ).toEqual({ valid: false, providerOperationId: null });
    }
    expect(
      submittedProviderOperationBinding(
        "HYPOTHESIS",
        { kind: "HYPOTHESIS" },
        undefined,
      ),
    ).toEqual({ valid: true, providerOperationId: null });
    expect(
      submittedProviderOperationBinding(
        "HYPOTHESIS",
        { kind: "HYPOTHESIS" },
        "upgradeProviderModel",
      ),
    ).toEqual({ valid: false, providerOperationId: null });
  });

  it("fails closed for missing, unknown, or cross-kind provider payloads", () => {
    for (const payload of [
      {},
      { kind: "PROVIDER_CONTROL" },
      providerPayload("unknownProviderOperation"),
      { kind: "HYPOTHESIS", providerControl: {} },
    ]) {
      expect(providerOperationBinding("PROVIDER_CONTROL", payload)).toEqual({
        valid: false,
        providerOperationId: null,
      });
    }
    expect(
      providerOperationBinding(
        "HYPOTHESIS",
        providerPayload("upgradeProviderModel"),
      ),
    ).toEqual({ valid: false, providerOperationId: null });
    expect(
      providerOperationBinding("HYPOTHESIS", { kind: "PROVIDER_CONTROL" }),
    ).toEqual({ valid: false, providerOperationId: null });
    expect(
      providerOperationBinding("HYPOTHESIS", { kind: "HYPOTHESIS" }),
    ).toEqual({ valid: true, providerOperationId: null });
  });

  it.each(
    PROVIDER_CONTROL_OPERATION_IDS,
  )("emits one readonly exact provider operation field for %s", (providerOperationId) => {
    const fields = formsFor(
      approvalScreen,
      { params: {} },
      {
        selectedTarget: {
          actionKind: "PROVIDER_CONTROL",
          providerOperationId,
          proposalId: "11111111-1111-4111-8111-111111111111",
          assignmentId: "22222222-2222-4222-8222-222222222222",
          expectedProposalVersion: 3,
          expectedAssignmentVersion: 2,
          expectedApprovalDigest: "a".repeat(64),
        },
      },
    ).decide;
    expect(
      fields?.filter((field) => field.name === "providerOperationId"),
    ).toEqual([
      expect.objectContaining({
        name: "providerOperationId",
        value: providerOperationId,
        required: true,
        readonly: true,
      }),
    ]);
  });

  it("omits providerOperationId from non-provider decision forms", () => {
    const fields = formsFor(
      approvalScreen,
      { params: {} },
      {
        selectedTarget: {
          actionKind: "HYPOTHESIS",
          proposalId: "11111111-1111-4111-8111-111111111111",
          assignmentId: "22222222-2222-4222-8222-222222222222",
          expectedProposalVersion: 3,
          expectedAssignmentVersion: 2,
          expectedApprovalDigest: "a".repeat(64),
        },
      },
    ).decide;
    expect(fields?.some((field) => field.name === "providerOperationId")).toBe(
      false,
    );
  });

  it("uses ACTIVE_SESSION only for non-approval or connection-test approval", () => {
    for (const operationId of PROVIDER_CONTROL_OPERATION_IDS) {
      expect(
        providerDecisionAssurance("PROVIDER_CONTROL", operationId, {
          kind: "REJECT",
        }),
      ).toBe("ACTIVE_SESSION");
      expect(
        providerDecisionAssurance("PROVIDER_CONTROL", operationId, {
          kind: "CHANGES_REQUIRED",
        }),
      ).toBe("ACTIVE_SESSION");
    }
    expect(
      providerDecisionAssurance("PROVIDER_CONTROL", "testProviderConnection", {
        kind: "APPROVE",
      }),
    ).toBe("ACTIVE_SESSION");
  });

  it("requires STEP_UP for the three effect approvals and unknown approvals", () => {
    for (const operationId of [
      "disableProviderRouting",
      "upgradeProviderModel",
      "setModelAutoUpgrade",
      undefined,
      "unknownProviderOperation",
    ]) {
      expect(
        providerDecisionAssurance("PROVIDER_CONTROL", operationId, {
          kind: "APPROVE",
        }),
      ).toBe("STEP_UP");
    }
    expect(
      providerDecisionAssurance("HYPOTHESIS", undefined, { kind: "APPROVE" }),
    ).toBeUndefined();
  });

  it("canonicalizes only provider approvals to the complete decision schema", () => {
    expect(
      bindProviderDecision("PROVIDER_CONTROL", "testProviderConnection", {
        kind: "APPROVE",
        attestExactPreview: true,
      }),
    ).toEqual({
      requiredAssuranceLevel: "ACTIVE_SESSION",
      decision: {
        kind: "APPROVE",
        attestExactPreview: true,
        assurance: "ACTIVE_SESSION",
        stepUpAuthorizationId: null,
        assertedActionDigest: null,
        stepUpAt: null,
      },
    });
    expect(
      bindProviderDecision("PROVIDER_CONTROL", "upgradeProviderModel", {
        kind: "APPROVE",
        attestExactPreview: true,
      }),
    ).toMatchObject({
      requiredAssuranceLevel: "STEP_UP",
      decision: { assurance: "STEP_UP" },
    });

    const rejection = { kind: "REJECT", reason: "거부" };
    expect(
      bindProviderDecision(
        "PROVIDER_CONTROL",
        "upgradeProviderModel",
        rejection,
      ),
    ).toEqual({
      requiredAssuranceLevel: "ACTIVE_SESSION",
      decision: rejection,
    });
    expect(bindProviderDecision("HYPOTHESIS", undefined, rejection)).toEqual({
      decision: rejection,
    });
  });
});
