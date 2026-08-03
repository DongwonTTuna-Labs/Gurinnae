import { runCorrectionFlow } from "./submission-flow-cases-a";
import { runResponseFlow } from "./submission-flow-cases-b";
import {
  abuseProof,
  admin,
  equal,
  invoke,
  sessionToken,
  uuidField,
} from "./submission-flow-support";

type IntakeWriteCounts = {
  drafts: number;
  sessions: number;
};

function intakeWriteCounts(): IntakeWriteCounts {
  const value: unknown = JSON.parse(
    admin(`
      SELECT json_build_object(
        'drafts', (SELECT count(*) FROM intake.correction_request_drafts),
        'sessions', (SELECT count(*) FROM intake.submission_sessions)
      )::text
    `),
  );
  if (
    typeof value !== "object" ||
    value === null ||
    !("drafts" in value) ||
    !("sessions" in value) ||
    typeof value.drafts !== "number" ||
    typeof value.sessions !== "number"
  ) {
    throw new Error("intake write counts are invalid");
  }
  return { drafts: value.drafts, sessions: value.sessions };
}

async function expectRejectedPublicationBinding(
  label: string,
  value: Record<string, unknown>,
  expectedStatus: 400 | 404,
  expectedCode: "INVALID_REQUEST" | "RESOURCE_NOT_FOUND",
): Promise<void> {
  const before = intakeWriteCounts();
  const result = await invoke(
    "POST",
    "/v1/correction-session",
    {
      locale: "ko-KR",
      ...value,
      abuseProof: abuseProof("createCorrectionRequestDraft"),
    },
    { expected: expectedStatus },
  );
  equal(result.body.code, expectedCode, `${label} problem code`);
  equal(intakeWriteCounts().drafts, before.drafts, `${label} draft writes`);
  equal(
    intakeWriteCounts().sessions,
    before.sessions,
    `${label} session writes`,
  );
}

async function runCorrectionPublicationBindingFlow(): Promise<void> {
  const before = intakeWriteCounts();
  const created = await invoke(
    "POST",
    "/v1/correction-session",
    {
      locale: "ko-KR",
      caseSlug: "integration-case",
      publicationRevision: 1,
      abuseProof: abuseProof("createCorrectionRequestDraft"),
    },
    { expected: 201 },
  );
  const draftId = uuidField(created.body, "aggregateId");
  sessionToken(created.body, "session");
  const after = intakeWriteCounts();
  equal(
    after.drafts,
    before.drafts + 1,
    "valid publication binding draft write",
  );
  equal(
    after.sessions,
    before.sessions + 1,
    "valid publication binding session write",
  );
  equal(
    admin(`
      SELECT count(*)
      FROM intake.correction_request_drafts AS draft
      JOIN intake.submission_sessions AS session
        ON session.scope_id = draft.id
      WHERE draft.id = '${draftId}'::uuid
        AND draft.case_slug = 'integration-case'
        AND draft.publication_revision = 1
        AND session.session_kind = 'CORRECTION_DRAFT'
        AND session.scope_type = 'CORRECTION_DRAFT'
        AND session.status = 'ACTIVE'
    `),
    "1",
    "valid publication binding persisted pair",
  );

  await expectRejectedPublicationBinding(
    "slug-only publication binding",
    { caseSlug: "integration-case" },
    400,
    "INVALID_REQUEST",
  );
  await expectRejectedPublicationBinding(
    "revision-only publication binding",
    { publicationRevision: 1 },
    400,
    "INVALID_REQUEST",
  );
  await expectRejectedPublicationBinding(
    "unknown-slug publication binding",
    { caseSlug: "missing-public-case", publicationRevision: 1 },
    404,
    "RESOURCE_NOT_FOUND",
  );
  await expectRejectedPublicationBinding(
    "unknown-revision publication binding",
    { caseSlug: "integration-case", publicationRevision: 99 },
    404,
    "RESOURCE_NOT_FOUND",
  );
  await expectRejectedPublicationBinding(
    "mismatched publication binding",
    { caseSlug: "integration-case", publicationRevision: 2 },
    404,
    "RESOURCE_NOT_FOUND",
  );
  console.log("PUB-027 correction publication binding atomic validation: PASS");
}

await runCorrectionPublicationBindingFlow();
await runCorrectionFlow();
await runResponseFlow();

console.log(
  "submission 34-operation/session/encryption/object-bytes/ClamAV integration: PASS",
);
