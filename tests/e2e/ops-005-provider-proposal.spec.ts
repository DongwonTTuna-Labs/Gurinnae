import {
  type APIRequestContext,
  expect,
  type Locator,
  type Page,
  test,
} from "@playwright/test";

const mock = "http://127.0.0.1:29100";
const review = "http://127.0.0.1:29102";
const providerPath = "/internal/operations/providers";
const approvalPath = "/internal/my-work";
const activeModel = "relay-test-latest";

const scenarios = [
  {
    operationId: "disableProviderRouting",
    actionId: "disable-routing",
    requiresStepUp: true,
  },
  {
    operationId: "testProviderConnection",
    actionId: "test",
    modelField: "testModel",
    requiresStepUp: false,
  },
  {
    operationId: "upgradeProviderModel",
    actionId: "upgrade-model",
    modelField: "modelId",
    requiresStepUp: true,
    tamperBeforeApproval: true,
  },
  {
    operationId: "setModelAutoUpgrade",
    actionId: "auto-upgrade",
    enabled: true,
    requiresStepUp: true,
  },
] as const;

type ProviderControlOperationId = (typeof scenarios)[number]["operationId"];

type ProviderProposal = {
  proposalId: string;
  version: number;
  state: string;
  contentDigest: string;
  approvalDigest: string;
  payload: {
    kind: string;
    providerControl: { operationId: ProviderControlOperationId };
  };
};

type MockState = {
  stepUpStartCount: number;
  stepUpCallbackCount: number;
  authorizationCloseCount: number;
  assertionOperations: Array<{ operationId: string }>;
  providerControl: {
    proposals: ProviderProposal[];
    events: Array<{
      operationId: string;
      providerOperationId: ProviderControlOperationId;
      proposalId: string;
      state: string;
    }>;
    directCommandAttempts: Array<{ operationId: ProviderControlOperationId }>;
  };
};

async function resetAndLogin(
  page: Page,
  request: APIRequestContext,
): Promise<void> {
  const reset = await request.post(`${mock}/_test/reset`);
  expect(reset.ok()).toBe(true);
  await page.goto(
    `${review}/auth/login?returnTo=${encodeURIComponent(providerPath)}`,
    { waitUntil: "networkidle" },
  );
  await expect(page).toHaveURL(`${review}${providerPath}`);
  await expect(page.locator('main[data-screen-id="OPS-005"]')).toBeVisible();
}

async function readState(request: APIRequestContext): Promise<MockState> {
  const response = await request.get(`${mock}/_test/state`);
  expect(response.ok()).toBe(true);
  return (await response.json()) as MockState;
}

async function fillProviderForm(
  form: Locator,
  scenario: (typeof scenarios)[number],
): Promise<void> {
  await expect(form).toBeVisible();
  await form
    .locator('[name="reason"]')
    .fill(`${scenario.operationId} 제안 브라우저 결속 확인`);
  if ("modelField" in scenario) {
    await form
      .locator(`select[name="${scenario.modelField}"]`)
      .selectOption(activeModel);
  }
  if ("enabled" in scenario) {
    await form.locator('input[name="enabled"]').check();
    const track = form.locator('input[name="track"]');
    if ((await track.inputValue()) === "") await track.fill("relay-test-");
  }
}

async function submitProposal(
  page: Page,
  scenario: (typeof scenarios)[number],
): Promise<string> {
  const form = page.locator(`form[data-action-id="${scenario.actionId}"]`);
  await fillProviderForm(form, scenario);
  await Promise.all([
    page.waitForURL((url) => {
      return (
        url.pathname === approvalPath &&
        Boolean(url.searchParams.get("proposalId"))
      );
    }),
    form.locator('button[type="submit"]').click(),
  ]);
  const proposalId = new URL(page.url()).searchParams.get("proposalId");
  expect(proposalId).toMatch(
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
  );
  if (!proposalId) throw new Error("proposal redirect omitted proposalId");
  return proposalId;
}

async function advanceProposalToClaimedReview(
  request: APIRequestContext,
  proposal: ProviderProposal,
): Promise<void> {
  // The product has no browser shortcut from draft to review. Exercise the
  // existing governed API lifecycle so the following browser decision starts
  // from a real claimed assignment rather than from injected page state.
  const previewResponse = await request.post(
    `${mock}/v1/internal/action-proposals/${proposal.proposalId}:preview`,
    {
      data: {
        proposalId: proposal.proposalId,
        expectedVersion: proposal.version,
        expectedContentDigest: proposal.contentDigest,
      },
    },
  );
  expect(previewResponse.status()).toBe(201);
  const previewBody = (await previewResponse.json()) as {
    preview: { previewId: string; previewDigest: string };
  };

  const reviewResponse = await request.post(
    `${mock}/v1/internal/action-proposals/${proposal.proposalId}:submit-review`,
    {
      data: {
        proposalId: proposal.proposalId,
        expectedVersion: proposal.version,
        expectedContentDigest: proposal.contentDigest,
        previewId: previewBody.preview.previewId,
        previewDigest: previewBody.preview.previewDigest,
      },
    },
  );
  expect(reviewResponse.status()).toBe(200);
  const reviewBody = (await reviewResponse.json()) as {
    proposal: { version: number; approvalDigest: string };
    assignments: Array<{ assignmentId: string; version: number }>;
  };
  const assignment = reviewBody.assignments[0];
  if (!assignment) throw new Error("provider review assignment is missing");

  const claimResponse = await request.post(
    `${mock}/v1/internal/action-proposals/${proposal.proposalId}:claim-review`,
    {
      data: {
        proposalId: proposal.proposalId,
        assignmentId: assignment.assignmentId,
        expectedProposalVersion: reviewBody.proposal.version,
        expectedAssignmentVersion: assignment.version,
        expectedApprovalDigest: reviewBody.proposal.approvalDigest,
      },
    },
  );
  expect(claimResponse.status()).toBe(200);
}

async function openApproval(
  page: Page,
  proposalId: string,
  operationId: ProviderControlOperationId,
): Promise<Locator> {
  await page.goto(
    `${review}${approvalPath}?proposalId=${encodeURIComponent(proposalId)}`,
    { waitUntil: "networkidle" },
  );
  const approve = page.locator('[data-decision="approve"]');
  await expect(approve).toBeVisible();
  await approve.click();
  const dialog = page.locator("#approval-decision-int-002");
  await expect(dialog).toBeVisible();
  await expect(dialog.locator('input[name="providerOperationId"]')).toHaveValue(
    operationId,
  );
  await dialog
    .locator('textarea[name="reason"]')
    .fill("공급자 작업·버전·승인 지문을 확인했습니다.");
  return dialog;
}

async function assertTamperingFailsClosed(
  page: Page,
  request: APIRequestContext,
  proposalId: string,
): Promise<void> {
  const dialog = await openApproval(page, proposalId, "upgradeProviderModel");
  await dialog
    .locator('input[name="providerOperationId"]')
    .evaluate((input) => {
      if (!(input instanceof HTMLInputElement))
        throw new Error("provider operation binding is not an input");
      input.value = "testProviderConnection";
    });
  const failedResponse = page.waitForResponse(
    (response) =>
      response.request().method() === "POST" &&
      new URL(response.url()).pathname === approvalPath,
  );
  await dialog.getByRole("button", { name: "예, 승인 기록" }).click();
  expect((await failedResponse).status()).toBe(409);

  const state = await readState(request);
  expect(state.providerControl.events.at(-1)?.operationId).toBe(
    "claimActionReview",
  );
  expect(state.stepUpStartCount).toBe(0);
  expect(
    state.assertionOperations.some(
      ({ operationId }) => operationId === "submitActionDecision",
    ),
  ).toBe(false);
}

test.describe("[OPS-005] governed provider-control browser routing", () => {
  for (const scenario of scenarios) {
    test(`${scenario.operationId} creates and approves only a bound proposal`, async ({
      page,
      request,
    }) => {
      await resetAndLogin(page, request);
      const proposalId = await submitProposal(page, scenario);
      const created = await readState(request);

      expect(created.providerControl.proposals).toHaveLength(1);
      const proposal = created.providerControl.proposals[0];
      if (!proposal) throw new Error("provider proposal was not recorded");
      expect(proposal).toMatchObject({
        proposalId,
        state: "DRAFT",
        payload: {
          kind: "PROVIDER_CONTROL",
          providerControl: { operationId: scenario.operationId },
        },
      });
      expect(created.providerControl.events).toEqual([
        {
          operationId: "createActionProposal",
          providerOperationId: scenario.operationId,
          proposalId,
          state: "DRAFT",
        },
      ]);
      expect(created.providerControl.directCommandAttempts).toEqual([]);
      expect(
        created.assertionOperations.map(({ operationId }) => operationId),
      ).toContain("createActionProposal");
      expect(
        created.assertionOperations.map(({ operationId }) => operationId),
      ).not.toContain(scenario.operationId);

      await advanceProposalToClaimedReview(request, proposal);
      if ("tamperBeforeApproval" in scenario) {
        await assertTamperingFailsClosed(page, request, proposalId);
      }

      const dialog = await openApproval(page, proposalId, scenario.operationId);
      await dialog.getByRole("button", { name: "예, 승인 기록" }).click();
      await expect
        .poll(async () => {
          const state = await readState(request);
          return state.providerControl.events.at(-1)?.operationId;
        })
        .toBe("submitActionDecision");

      const approved = await readState(request);
      expect(approved.providerControl.proposals[0]?.state).toBe("APPROVED");
      expect(approved.providerControl.directCommandAttempts).toEqual([]);
      expect(
        approved.assertionOperations.map(({ operationId }) => operationId),
      ).not.toContain(scenario.operationId);
      expect(
        approved.assertionOperations.map(({ operationId }) => operationId),
      ).toContain("submitActionDecision");
      expect(approved.stepUpStartCount).toBe(scenario.requiresStepUp ? 1 : 0);
      expect(approved.stepUpCallbackCount).toBe(
        scenario.requiresStepUp ? 1 : 0,
      );
      expect(approved.authorizationCloseCount).toBe(
        scenario.requiresStepUp ? 1 : 0,
      );
    });
  }
});
