import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { expect, test } from "@playwright/test";
import { sha256, state } from "./submission-routing.shared";
import "./submission-routing-token.helpers";

test("failed scoped form actions expose the server error to the user", async ({
  page,
}) => {
  await page.goto(
    `http://127.0.0.1:29103/respond/access?token=${encodeURIComponent(`response-invalid-otp-${randomUUID()}`)}`,
    { waitUntil: "networkidle" },
  );
  const verify = page.locator('form[data-action-id="verify"]');
  await verify.locator('input[name="emailOtp"]').fill("000000");
  await verify.locator('button[type="submit"]').click();
  await expect(page.locator(".action-error-host .error-summary")).toContainText(
    "남은 시도 횟수: 4",
  );
  await expect(verify).toHaveCount(1);
});

test("empty token parameters are exchanged and removed from the URL", async ({
  page,
}) => {
  await page.goto("http://127.0.0.1:29103/respond/access?token=", {
    waitUntil: "networkidle",
  });
  expect(page.url()).not.toContain("token=");
  await expect(page.locator(".notice")).toContainText(
    "ONE_TIME_TOKEN_REQUIRED",
  );
});

test("response request downloads decode the submission binary", async ({
  page,
}) => {
  const oneTimeToken = `response-download-${randomUUID()}`;
  await page.goto(
    `http://127.0.0.1:29103/respond/access?token=${encodeURIComponent(oneTimeToken)}`,
    { waitUntil: "networkidle" },
  );
  await page.goto("http://127.0.0.1:29103/respond/overview", {
    waitUntil: "networkidle",
  });
  const download = page.waitForEvent("download");
  await page.locator('[data-action-id="download-request"]').click();
  const artifact = await download;
  expect(artifact.suggestedFilename()).toBe("rsp-002-download-request.json");
  const path = await artifact.path();
  expect(path).not.toBeNull();
  expect(await readFile(path as string, "utf8")).toContain(
    "77777777-7777-4777-8777-777777777777",
  );
});

test("anonymous correction flow creates a scoped draft before save and rotates to a receipt", async ({
  page,
  request,
}) => {
  await page.goto("http://127.0.0.1:29101/correction-request", {
    waitUntil: "networkidle",
  });
  await expect(page.locator(".error-summary")).toHaveCount(0);
  await expect(page.getByText("제출 세션이 필요합니다.")).toHaveCount(0);
  await expect(page.locator('form[data-action-id="save-draft"]')).toHaveCount(
    1,
  );
  await expect(
    page.locator('form[data-action-id="submit-correction"]'),
  ).toHaveCount(0);

  const save = page.locator('form[data-action-id="save-draft"]');
  await save.locator('input[name="caseSlug"]').fill("e2e-case");
  await save.locator('input[name="publicationRevision"]').fill("3");
  await save.locator('input[name="requesterType"]').fill("CITIZEN");
  await save
    .locator('input[name="contactEmail"]')
    .fill("requester@example.test");
  await save
    .locator('input[name="summary"]')
    .fill("공개 문장의 수치를 바로잡아 주세요.");
  await save
    .locator('textarea[name="requestedChanges"]')
    .fill('["계약 금액을 원문과 일치시켜 주세요."]');
  await save
    .locator('input[name="evidenceDescription"]')
    .fill("공개 원문 링크를 확인했습니다.");
  await expect(save.locator('button[type="submit"]')).toBeEnabled();
  await save.locator('button[type="submit"]').click();
  await page.waitForURL(/\/correction-request\?notice=/);

  const correctionBytes = Buffer.from("correction attachment evidence\n");
  const upload = page.locator('form[data-action-id="upload-attachment"]');
  await upload.locator('input[name="attachment"]').setInputFiles({
    name: "evidence.txt",
    mimeType: "text/plain",
    buffer: correctionBytes,
  });
  await upload.locator('button[type="submit"]').click();
  await page.waitForURL(/\/correction-request\?notice=/);

  const removeAttachment = page.locator(
    'form[data-action-id="remove-attachment"]',
  );
  await expect(removeAttachment).toContainText("evidence.txt");
  await removeAttachment.locator('button[type="submit"]').click();
  await expect(page.locator(".notice")).toContainText("첨부 파일 제거 완료");
  await expect(removeAttachment).toHaveCount(0);

  const replacementBytes = Buffer.from(
    "replacement correction attachment evidence\n",
  );
  const replacementUpload = page.locator(
    'form[data-action-id="upload-attachment"]',
  );
  await replacementUpload.locator('input[name="attachment"]').setInputFiles({
    name: "evidence-replacement.txt",
    mimeType: "text/plain",
    buffer: replacementBytes,
  });
  await replacementUpload.locator('button[type="submit"]').click();
  await expect(
    page.locator('form[data-action-id="remove-attachment"]'),
  ).toContainText("evidence-replacement.txt");

  const submit = page.locator('form[data-action-id="submit-correction"]');
  await expect(submit).toHaveCount(1);
  await expect(submit.locator('input[name="expectedVersion"]')).toHaveValue(
    "2",
  );
  await submit.locator('input[name="attestation"]').check();
  await submit.locator('input[name="privacyConsent"]').check();
  await submit.locator('button[type="submit"]').click();
  await page.waitForURL(/\/correction-request\/receipt\?notice=/);
  await expect(page.locator(".error-summary")).toHaveCount(0);

  const observed = await state(request);
  expect(
    observed.submissionWrites.map(({ method, path }) => ({ method, path })),
  ).toEqual(
    expect.arrayContaining([
      { method: "POST", path: "/v1/correction-session" },
      { method: "PUT", path: "/v1/correction-session" },
      { method: "POST", path: "/v1/correction-session:submit" },
    ]),
  );
  expect(
    observed.submissionWrites
      .filter(
        ({ path }) =>
          path.startsWith("/v1/correction-session") &&
          path !== "/v1/correction-session",
      )
      .every(({ sessionTokenSha256 }) => sessionTokenSha256.length === 64),
  ).toBe(true);
  expect(
    observed.submissionWrites.some(
      ({ method, path }) =>
        method === "DELETE" &&
        path.startsWith("/v1/correction-session/attachments/"),
    ),
  ).toBe(true);
  expect(observed.attachmentUploads).toContainEqual(
    expect.objectContaining({
      kind: "correction",
      sizeBytes: replacementBytes.byteLength,
      sha256: sha256(replacementBytes.toString()),
      uploaded: true,
      finalized: true,
    }),
  );
});

test("response flow verifies access, saves the latest draft version, and rotates to a receipt", async ({
  page,
  request,
}) => {
  const oneTimeToken = `response-submit-${randomUUID()}`;
  await page.goto(
    `http://127.0.0.1:29103/respond/access?token=${encodeURIComponent(oneTimeToken)}`,
    { waitUntil: "networkidle" },
  );

  const verify = page.locator('form[data-action-id="verify"]');
  await verify.locator('input[name="emailOtp"]').fill("123456");
  await verify.locator('button[type="submit"]').click();
  await page.waitForURL(/\/respond\/access\?notice=/);

  await page.goto("http://127.0.0.1:29103/respond/answer", {
    waitUntil: "networkidle",
  });
  const save = page.locator('form[data-action-id="save-draft"]');
  await expect(save.locator('input[name="expectedVersion"]')).toHaveValue("3");
  await save
    .locator('textarea[aria-label="질문 1 답변"]')
    .fill("요청받은 사실관계를 확인했습니다.");
  const consent = save.locator(
    '.structured-json-field[data-field-name="publicationConsent"]',
  );
  await consent.locator('input[type="checkbox"]').nth(0).check();
  await consent.locator('input[type="checkbox"]').nth(1).check();
  await expect
    .poll(async () =>
      JSON.parse(await save.locator('textarea[name="answers"]').inputValue()),
    )
    .toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          text: "요청받은 사실관계를 확인했습니다.",
        }),
      ]),
    );
  await expect
    .poll(async () =>
      JSON.parse(
        await save.locator('textarea[name="publicationConsent"]').inputValue(),
      ),
    )
    .toEqual(
      expect.objectContaining({
        bodyConsent: true,
        redactionAcknowledged: true,
      }),
    );
  await save.locator('button[type="submit"]').click();
  await page.waitForURL(/\/respond\/answer\?notice=/);

  await page.goto("http://127.0.0.1:29103/respond/attachments", {
    waitUntil: "networkidle",
  });
  const responseBytes = Buffer.from("response attachment evidence\n");
  const upload = page.locator('form[data-action-id="select-file"]');
  await upload.locator('input[name="attachment"]').setInputFiles({
    name: "response.txt",
    mimeType: "text/plain",
    buffer: responseBytes,
  });
  await upload.locator('button[type="submit"]').click();
  await page.waitForURL(/\/respond\/attachments\?notice=/);

  const removeAttachment = page.locator('form[data-action-id="remove-file"]');
  await expect(removeAttachment).toContainText("response.txt");
  await removeAttachment.locator('button[type="submit"]').click();
  await expect(page.locator(".notice")).toContainText("파일 제거 완료");
  await expect(removeAttachment).toHaveCount(0);

  const replacementBytes = Buffer.from(
    "replacement response attachment evidence\n",
  );
  const replacementUpload = page.locator('form[data-action-id="select-file"]');
  await replacementUpload.locator('input[name="attachment"]').setInputFiles({
    name: "response-replacement.txt",
    mimeType: "text/plain",
    buffer: replacementBytes,
  });
  await replacementUpload.locator('button[type="submit"]').click();
  await expect(
    page.locator('form[data-action-id="remove-file"]'),
  ).toContainText("response-replacement.txt");

  await page.goto("http://127.0.0.1:29103/respond/review", {
    waitUntil: "networkidle",
  });
  const submit = page.locator('form[data-action-id="submit"]');
  await expect(submit.locator('input[name="expectedVersion"]')).toHaveValue(
    "4",
  );
  await submit.locator('input[name="attestation"]').check();
  await submit.locator('textarea[name="publicationConsent"]').fill(
    JSON.stringify({
      bodyConsent: true,
      attachmentConsents: [],
      identityDisplay: "ORGANIZATION_NAME",
      redactionAcknowledged: true,
      excerptReviewRequested: false,
      consentedAt: "2026-07-13T00:00:00Z",
    }),
  );
  await submit.locator('button[type="submit"]').click();
  await page.waitForURL(/\/respond\/receipt\?notice=/);
  await expect(page.locator(".error-summary")).toHaveCount(0);

  const observed = await state(request);
  expect(
    observed.submissionWrites.map(({ method, path }) => ({ method, path })),
  ).toEqual(
    expect.arrayContaining([
      { method: "POST", path: "/v1/response-session:verify" },
      { method: "PUT", path: "/v1/response-session/draft" },
      { method: "POST", path: "/v1/response-session:submit" },
    ]),
  );
  expect(observed.submissionReads.map(({ path }) => path)).toEqual(
    expect.arrayContaining([
      "/v1/response-session/draft",
      "/v1/response-session/preview",
      "/v1/response-receipt",
    ]),
  );
  expect(
    observed.submissionWrites.some(
      ({ method, path }) =>
        method === "DELETE" &&
        path.startsWith("/v1/response-session/attachments/"),
    ),
  ).toBe(true);
  expect(observed.attachmentUploads).toContainEqual(
    expect.objectContaining({
      kind: "response",
      sizeBytes: replacementBytes.byteLength,
      sha256: sha256(replacementBytes.toString()),
      uploaded: true,
      finalized: true,
    }),
  );
});

test("subscription flow persists the pending session and consumes verification into management", async ({
  page,
  request,
  context,
}) => {
  await page.goto("http://127.0.0.1:29101/subscribe", {
    waitUntil: "networkidle",
  });
  const create = page.locator('form[data-action-id="request-verification"]');
  await create.locator('input[name="email"]').fill("reader@example.test");
  await create.locator('select[name="scopeType"]').selectOption("GLOBAL");
  await create.locator('select[name="frequency"]').selectOption("DAILY");
  await create.locator('input[name="locale"]').fill("ko-KR");
  await create.locator('input[name="consent"]').check();
  await expect(create.locator('button[type="submit"]')).toBeEnabled();
  await create.locator('button[type="submit"]').click();
  await page.waitForURL(/\/subscribe\?notice=/);

  const pending = (await context.cookies()).find(
    (cookie) => cookie.name === "gurine_subscription_session",
  );
  expect(pending).toMatchObject({
    httpOnly: true,
    path: "/subscription",
    sameSite: "Lax",
  });

  const verificationToken = `subscription-verify-${randomUUID()}`;
  await page.goto(
    `http://127.0.0.1:29101/subscribe?token=${encodeURIComponent(verificationToken)}`,
    { waitUntil: "networkidle" },
  );
  await expect(page).toHaveURL(/\/subscription\/manage\?notice=/);
  expect(page.url()).not.toContain("token=");
  await expect(page.locator(".error-summary")).toHaveCount(0);

  const observed = await state(request);
  expect(
    observed.submissionWrites.map(({ method, path }) => ({ method, path })),
  ).toEqual(
    expect.arrayContaining([
      { method: "POST", path: "/v1/subscription-session" },
      {
        method: "POST",
        path: "/v1/submission-session/subscription:verify",
      },
    ]),
  );
  expect(observed.submissionReads.map(({ path }) => path)).toContain(
    "/v1/subscription-session",
  );
});

test("scoped subscription presets remain server-bound through browser submission", async ({
  page,
  request,
}) => {
  const scopes = [
    {
      url: "http://127.0.0.1:29101/cases/integration-case",
      scopeType: "CASE",
      scopeRef: "integration-case",
    },
    {
      url: "http://127.0.0.1:29101/agencies/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      scopeType: "AGENCY",
      scopeRef: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    },
    {
      url: "http://127.0.0.1:29101/suppliers/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      scopeType: "SUPPLIER",
      scopeRef: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    },
    {
      url: "http://127.0.0.1:29101/corrections",
      scopeType: "CORRECTIONS",
    },
    {
      url: "http://127.0.0.1:29101/cases?publicationState=PUBLISHED_ANOMALY",
      scopeType: "QUERY",
    },
  ];

  for (const [index, scope] of scopes.entries()) {
    await page.goto(scope.url, { waitUntil: "networkidle" });
    const form = page.locator('form:has(input[name="scopeType"])').first();
    await expect(form.locator('select[name="scopeType"]')).toHaveCount(0);
    await expect(form.locator('input[name="scopeType"]')).toHaveValue(
      scope.scopeType,
    );
    await expect(form.locator('input[name="scopeType"] + output')).toHaveText(
      scope.scopeType,
    );
    if (scope.scopeRef) {
      await expect(form.locator('input[name="scopeRef"]')).toHaveValue(
        scope.scopeRef,
      );
    }
    await form
      .locator('input[name="email"]')
      .fill(`scoped-${index}@example.test`);
    await form.locator('select[name="frequency"]').selectOption("DAILY");
    await form.locator('input[name="locale"]').fill("ko-KR");
    await form.locator('input[name="consent"]').check();
    await expect(form.locator('button[type="submit"]')).toBeEnabled();
    await form.locator('button[type="submit"]').click();
    await page.waitForURL(/notice=/);

    const writes = (await state(request)).submissionWrites.filter(
      (write) =>
        write.method === "POST" && write.path === "/v1/subscription-session",
    );
    expect(writes.at(-1)).toMatchObject({
      scopeType: scope.scopeType,
      ...(scope.scopeRef ? { scopeRef: scope.scopeRef } : {}),
    });
  }
});

test("dataset download requests a real abuse-controlled export job", async ({
  page,
  request,
}) => {
  await page.goto("http://127.0.0.1:29101/data", {
    waitUntil: "networkidle",
  });
  const exportForm = page.locator('form[data-action-id="download-dataset"]');
  await exportForm.locator('input[name="datasetId"]').fill("published-cases");
  await exportForm.locator('select[name="format"]').selectOption("JSONL");
  await expect(exportForm.locator('button[type="submit"]')).toBeEnabled();
  await exportForm.locator('button[type="submit"]').click();
  await page.waitForURL(/\/data\?notice=/);
  const observed = await state(request);
  expect(observed.submissionWrites).toContainEqual(
    expect.objectContaining({ method: "POST", path: "/v1/dataset-exports" }),
  );
});
