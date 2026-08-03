import { expect, test } from "@playwright/test";

const review = "http://127.0.0.1:29102";
const mock = "http://127.0.0.1:29100";
const proposalId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const executionId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const approvalDigest = "2".repeat(64);
const bindingDigest = "3".repeat(64);

test.describe
  .serial("INT-002 server-bound approval journey", () => {
    test("decline serializes the journey enum and nullable reason code", async ({
      page,
      request,
    }) => {
      await request.post(`${mock}/_test/reset`);
      await page.goto(
        `${review}/auth/login?returnTo=${encodeURIComponent("/internal/my-work")}`,
        { waitUntil: "networkidle" },
      );
      await page
        .locator(`[data-proposal-id="${proposalId}"]`)
        .getByRole("link", { name: "이 제안 상세 확인" })
        .click();
      await page.locator('[data-decision="reject"]').click();
      const dialog = page.locator("#approval-decision-int-002");
      await expect(dialog).toBeVisible();
      await dialog
        .locator('textarea[name="reason"]')
        .fill("정책상 외부 전송을 보류합니다.");
      await dialog.getByRole("button", { name: "아니오, 반려" }).click();
      await expect(page).toHaveURL(/notice=|my-work/);
      const stateResponse = await request.get(`${mock}/_test/state`);
      const state = (await stateResponse.json()) as {
        actionJourney: {
          proposalState: string;
          events: Array<{ operationId: string }>;
        };
      };
      expect(state.actionJourney.proposalState).toBe("REJECTED");
      expect(state.actionJourney.events.at(-1)?.operationId).toBe(
        "submitActionDecision",
      );
    });

    test("queue → detail/digest → decision → handoff → receipt → destination", async ({
      page,
      request,
    }) => {
      await request.post(`${mock}/_test/reset`);

      // Login is a real browser redirect through the BFF.  No session cookie or
      // queue payload is injected into the page.
      await page.goto(
        `${review}/auth/login?returnTo=${encodeURIComponent("/internal/my-work")}`,
        { waitUntil: "networkidle" },
      );
      await expect(page).toHaveURL(`${review}/internal/my-work`);
      await expect(
        page.locator('main[data-screen-id="INT-002"]'),
      ).toBeVisible();

      // Queue → proposal detail is a server navigation.  The card must expose
      // the exact version and approval digest that the later command binds.
      const card = page.locator(`[data-proposal-id="${proposalId}"]`);
      await expect(card).toBeVisible();
      await expect(card).toContainText("v");
      await expect(card).toContainText(approvalDigest);
      await card.getByRole("link", { name: "이 제안 상세 확인" }).click();
      await expect(page).toHaveURL(new RegExp(`proposalId=${proposalId}`));
      await expect(
        page.locator('[aria-label="선택된 승인 대상"]'),
      ).toContainText(proposalId);
      await expect(
        page.locator('[aria-label="선택된 승인 대상"]'),
      ).toContainText(approvalDigest);

      // The initial detail has no handoff yet, therefore the decision dialog is
      // bound to submitActionDecision.  The BFF preflight re-reads this same
      // proposal/version/digest before the command is sent.
      await page.locator('[data-decision="approve"]').click();
      const decisionDialog = page.locator("#approval-decision-int-002");
      await expect(decisionDialog).toBeVisible();
      await decisionDialog
        .locator('textarea[name="reason"]')
        .fill("승인 지문과 수신자·본문을 대조했습니다.");
      await decisionDialog
        .getByRole("button", { name: "예, 승인 기록" })
        .click();
      await expect(page).toHaveURL(new RegExp(`executionId=${executionId}`));
      await expect(page.getByText("submitActionDecision 완료")).toBeVisible();

      // The receipt query is loaded by the server-rendered page using the
      // execution id returned from the decision response.
      await expect(
        page.locator('[data-testid="int_002__execution_receipt"]'),
      ).toBeVisible();
      await expect(
        page.locator('[data-testid="int_002__execution_receipt"]'),
      ).toContainText("종료 여부");

      // Approval creates a durable handoff binding.  Re-opening the proposal
      // proves that the binding digest/version came from a fresh API read.
      await page.goto(`${review}/internal/my-work?proposalId=${proposalId}`, {
        waitUntil: "networkidle",
      });
      await expect(
        page.locator('[aria-label="선택된 승인 대상"]'),
      ).toContainText(bindingDigest);
      await expect(page.locator('[data-decision="approve"]')).toBeVisible();

      // With a handoff present the same dialog switches to decideJourneyHandoff
      // and serializes ACKNOWLEDGE with the server-bound handoff version/digest.
      await page.locator('[data-decision="approve"]').click();
      await expect(decisionDialog).toBeVisible();
      await decisionDialog
        .getByRole("button", { name: "예, 승인 기록" })
        .click();
      await expect(page).toHaveURL(/decideJourneyHandoff|notice=/);

      const stateResponse = await request.get(`${mock}/_test/state`);
      expect(stateResponse.ok()).toBe(true);
      const state = (await stateResponse.json()) as {
        actionJourney: {
          proposalState: string;
          handoffState: string;
          executionId: string | null;
          events: Array<{
            operationId: string;
            before: string;
            after: string;
            digest: string;
          }>;
        };
      };
      expect(state.actionJourney.proposalState).toBe("APPROVED");
      expect(state.actionJourney.handoffState).toBe("ACKNOWLEDGED");
      expect(state.actionJourney.executionId).toBe(executionId);
      expect(
        state.actionJourney.events.map((event) => event.operationId),
      ).toEqual(["submitActionDecision", "decideJourneyHandoff"]);
      expect(state.actionJourney.events[0]?.digest).toBe(approvalDigest);
      expect(state.actionJourney.events[1]?.digest).toBe(bindingDigest);

      // Finally read the server receipt and assert the external destination is
      // carried by the receipt chain, not inferred from a client-side fixture.
      const receipt = await request.get(
        `${mock}/v1/internal/action-executions/${executionId}/receipt`,
      );
      expect(receipt.ok()).toBe(true);
      const receiptBody = (await receipt.json()) as {
        terminal: boolean;
        reconciliationRequired: boolean;
        binding: { destination: string; approvalDigest: string };
        receipts: Array<{ state: string; destination: string }>;
      };
      expect(receiptBody.terminal).toBe(true);
      expect(receiptBody.reconciliationRequired).toBe(false);
      expect(receiptBody.binding.approvalDigest).toBe(approvalDigest);
      expect(receiptBody.binding.destination).toBe("destination@example.test");
      expect(receiptBody.receipts[0]).toMatchObject({
        state: "DELIVERED",
        destination: "destination@example.test",
      });
    });
  });
