import { createHash, randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { expect, test } from "@playwright/test";

const mock = "http://127.0.0.1:29100";

type MockState = {
  submissionExchanges: Array<{
    path: string;
    tokenSha256: string;
    sessionKind: string;
  }>;
  submissionReads: Array<{ path: string; sessionTokenSha256: string }>;
  submissionWrites: Array<{
    method: string;
    path: string;
    sessionTokenSha256: string;
    bodySha256: string;
  }>;
  attachmentUploads: Array<{
    id: string;
    kind: "correction" | "response";
    sizeBytes: number;
    sha256: string;
    uploaded: boolean;
    finalized: boolean;
  }>;
};

const sha256 = (value: string) =>
  createHash("sha256").update(value).digest("hex");

async function state(request: import("@playwright/test").APIRequestContext) {
  const response = await request.get(`${mock}/_test/state`);
  expect(response.ok()).toBe(true);
  return (await response.json()) as MockState;
}

test("magic-link exchanges use no-referrer while canonical forms retain a same-origin Origin", async ({
  request,
}) => {
  for (const contract of [
    {
      exchange: "http://127.0.0.1:29103/respond/access",
      canonical: "http://127.0.0.1:29103/respond/access",
    },
    {
      exchange: "http://127.0.0.1:29101/correction-request/receipt",
      canonical: "http://127.0.0.1:29101/correction-request/receipt",
    },
  ]) {
    const response = await request.get(
      `${contract.exchange}?token=${encodeURIComponent(`referrer-${randomUUID()}`)}`,
      { maxRedirects: 0 },
    );
    expect(response.status()).toBe(303);
    expect(response.headers()["referrer-policy"]).toBe("no-referrer");
    expect(response.headers().location).toBe(
      new URL(contract.canonical).pathname,
    );

    const canonical = await request.get(contract.canonical);
    expect(canonical.status()).toBe(200);
    expect(canonical.headers()["referrer-policy"]).toBe(
      "strict-origin-when-cross-origin",
    );
  }
});

for (const contract of [
  {
    name: "response access",
    url: "http://127.0.0.1:29103/respond/access",
    exchangePath: "/v1/submission-session/response:exchange",
    readPath: "/v1/response-session/access-status",
  },
  {
    name: "response receipt",
    url: "http://127.0.0.1:29103/respond/receipt",
    exchangePath: "/v1/submission-session/response-receipt:exchange",
    readPath: "/v1/response-receipt",
  },
  {
    name: "correction receipt",
    url: "http://127.0.0.1:29101/correction-request/receipt",
    exchangePath: "/v1/submission-session/correction-receipt:exchange",
    readPath: "/v1/correction-receipt",
  },
  {
    name: "subscription management",
    url: "http://127.0.0.1:29101/subscription/manage",
    exchangePath: "/v1/submission-session/subscription-management:exchange",
    readPath: "/v1/subscription-session",
  },
]) {
  test(`${contract.name} exchanges the token and uses the submission client`, async ({
    page,
    request,
  }) => {
    const oneTimeToken = `${contract.name}-${randomUUID()}`;
    await page.goto(
      `${contract.url}?token=${encodeURIComponent(oneTimeToken)}`,
      {
        waitUntil: "networkidle",
      },
    );
    expect(page.url()).toBe(contract.url);
    const observed = await state(request);
    expect(observed.submissionExchanges).toContainEqual(
      expect.objectContaining({
        path: contract.exchangePath,
        tokenSha256: sha256(oneTimeToken),
      }),
    );
    expect(observed.submissionReads).toContainEqual(
      expect.objectContaining({ path: contract.readPath }),
    );
  });
}

test("failed token exchange removes the bearer token from the URL", async ({
  page,
}) => {
  const oneTimeToken = `invalid-${randomUUID()}`;
  await page.goto(
    `http://127.0.0.1:29103/respond/access?token=${encodeURIComponent(oneTimeToken)}`,
    { waitUntil: "networkidle" },
  );
  expect(page.url()).not.toContain("token=");
  expect(page.url()).not.toContain(encodeURIComponent(oneTimeToken));
  await expect(page.locator(".notice")).toContainText("ONE_TIME_TOKEN_INVALID");
});

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
  await save.locator('textarea[name="answers"]').fill(
    JSON.stringify([
      {
        questionId: "question-1",
        text: "요청받은 사실관계를 확인했습니다.",
        attachmentIds: [],
        updatedAt: "2026-07-13T00:00:00Z",
      },
    ]),
  );
  await save.locator('textarea[name="publicationConsent"]').fill(
    JSON.stringify({
      bodyConsent: true,
      attachmentConsents: [],
      identityDisplay: "ORGANIZATION_NAME",
      redactionAcknowledged: true,
      excerptReviewRequested: false,
      consentedAt: "2026-07-13T00:00:00Z",
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
