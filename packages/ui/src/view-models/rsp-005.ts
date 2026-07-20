/** Typed, display-safe projection for the final response review screen. */

export type Rsp005Answer = {
  questionId: string | null;
  questionLabel: string | null;
  text: string | null;
  attachmentIds: readonly string[];
  updatedAt: string | null;
};

export type Rsp005Attachment = {
  id: string | null;
  filename: string | null;
  mediaType: string | null;
  sizeBytes: number | null;
  sha256: string | null;
  uploadStatus: string | null;
  scanStatus: string | null;
};

export type Rsp005ViewModel = {
  request: {
    requestId: string | null;
    casePublicTitle: string | null;
    partyName: string | null;
    dueAt: string | null;
    status: string | null;
    questionCount: number | null;
  };
  answers: readonly Rsp005Answer[];
  attachments: readonly Rsp005Attachment[];
  consent: {
    body: boolean | null;
    redactionAcknowledged: boolean | null;
    scopeExplanation: string | null;
    updatedAt: string | null;
    attachmentCount: number;
  };
  authority: {
    status: "CONFIRMED" | "UNKNOWN";
    reason: string;
  };
  consequence: {
    warnings: readonly string[];
    missingAnswerCount: number;
    pendingAttachmentCount: number;
    blocked: boolean;
  };
  submissionDigest: string | null;
};

const record = (value: unknown): Record<string, unknown> | null =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
const text = (value: unknown): string | null =>
  typeof value === "string" && value.trim().length > 0 ? value : null;
const integer = (value: unknown): number | null =>
  typeof value === "number" && Number.isInteger(value) && value >= 0
    ? value
    : null;
const strings = (value: unknown): string[] =>
  Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];

function answers(value: unknown): Rsp005Answer[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((item) => {
    const row = record(item);
    if (!row) return [];
    return [
      {
        questionId: text(row.questionId),
        questionLabel: text(
          row.questionText ?? row.label ?? row.prompt ?? row.title,
        ),
        text: text(row.text),
        attachmentIds: strings(row.attachmentIds),
        updatedAt: text(row.updatedAt),
      } satisfies Rsp005Answer,
    ];
  });
}

function attachments(value: unknown): Rsp005Attachment[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((item) => {
    const row = record(item);
    if (!row) return [];
    return [
      {
        id: text(row.id),
        filename: text(row.filename),
        mediaType: text(row.mediaType),
        sizeBytes: integer(row.sizeBytes),
        sha256: text(row.sha256),
        uploadStatus: text(row.uploadStatus),
        scanStatus: text(row.scanStatus),
      } satisfies Rsp005Attachment,
    ];
  });
}

/**
 * A preview is not proof of authority.  The authority section therefore stays
 * UNKNOWN unless the server explicitly supplies a boolean confirmation.  This
 * prevents a missing attestation from becoming a green submit button.
 */
export function toRsp005ViewModel(
  data: Record<string, unknown>,
): Rsp005ViewModel {
  const preview = record(data.getResponseSubmissionPreview) ?? {};
  const request = record(preview.request) ?? {};
  const consent = record(preview.publicationConsent) ?? {};
  const authority = record(preview.authority);
  const answerRows = answers(preview.answers);
  const attachmentRows = attachments(preview.attachments);
  const warnings = strings(preview.warnings);
  const missingAnswerCount = answerRows.filter(
    (item) => item.text === null,
  ).length;
  const pendingAttachmentCount =
    attachmentRows.filter(
      (item) =>
        item.uploadStatus !== null &&
        item.uploadStatus.toUpperCase() !== "COMPLETED" &&
        item.uploadStatus.toUpperCase() !== "READY",
    ).length +
    attachmentRows.filter(
      (item) =>
        item.scanStatus !== null &&
        item.scanStatus.toUpperCase() !== "CLEAN" &&
        item.scanStatus.toUpperCase() !== "PASSED",
    ).length;
  const authorityConfirmed = authority?.confirmed;
  const explicitAuthority =
    typeof preview.authorityConfirmed === "boolean"
      ? preview.authorityConfirmed
      : typeof authorityConfirmed === "boolean"
        ? authorityConfirmed
        : null;
  const blocked =
    missingAnswerCount > 0 ||
    pendingAttachmentCount > 0 ||
    consent.redactionAcknowledged !== true ||
    explicitAuthority !== true ||
    warnings.length > 0;
  return {
    request: {
      requestId: text(request.requestId),
      casePublicTitle: text(request.casePublicTitle),
      partyName: text(request.partyName),
      dueAt: text(request.dueAt),
      status: text(request.status),
      questionCount: integer(request.questionCount),
    },
    answers: answerRows,
    attachments: attachmentRows,
    consent: {
      body:
        typeof consent.bodyConsent === "boolean"
          ? consent.bodyConsent
          : typeof consent.body === "boolean"
            ? consent.body
            : null,
      redactionAcknowledged:
        typeof consent.redactionAcknowledged === "boolean"
          ? consent.redactionAcknowledged
          : null,
      scopeExplanation: text(consent.scopeExplanation),
      updatedAt: text(consent.updatedAt),
      attachmentCount: Array.isArray(consent.attachmentConsents)
        ? consent.attachmentConsents.length
        : Array.isArray(consent.attachments)
          ? consent.attachments.length
          : 0,
    },
    authority: {
      status: explicitAuthority === true ? "CONFIRMED" : "UNKNOWN",
      reason:
        explicitAuthority === true
          ? "서버가 제출 권한을 확인했습니다."
          : "제출 권한은 최종 요청에서 서버가 확인해야 합니다.",
    },
    consequence: {
      warnings,
      missingAnswerCount,
      pendingAttachmentCount,
      blocked,
    },
    submissionDigest: text(preview.submissionDigest),
  };
}
