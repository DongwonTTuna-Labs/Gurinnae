export type Rsp006ViewModel = {
  receiptId: string | null;
  receiptTitle: string | null;
  receiptStatus: string | null;
  receiptVersion: number | null;
  submissionSummary: string | null;
  submittedItems: {
    requestId: string | null;
    submittedAt: string | null;
    submissionDigest: string | null;
    status: string | null;
    retentionNotice: string | null;
    answerCount: number | null;
    attachmentCount: number | null;
    publicationScope: string | null;
  };
  links: readonly { href: string; label: string; rel: string | null }[];
};

const record = (value: unknown): Record<string, unknown> | null =>
  typeof value === "object" && value !== null && !Array.isArray(value) ? value as Record<string, unknown> : null;
const text = (value: unknown): string | null => typeof value === "string" && value.trim() ? value : null;
const integer = (value: unknown): number | null => typeof value === "number" && Number.isInteger(value) ? value : null;

export function toRsp006ViewModel(data: Record<string, unknown>): Rsp006ViewModel {
  const response = record(data.getResponseReceipt) ?? {};
  const submitted = record(response.data) ?? {};
  const answers = Array.isArray(submitted.answers) ? submitted.answers : [];
  const attachments = Array.isArray(submitted.attachments) ? submitted.attachments : [];
  const consent = record(submitted.publicationConsent);
  const links = Array.isArray(response.links) ? response.links.map(record).filter((item): item is Record<string, unknown> => item !== null).flatMap((item) => {
    const href = text(item.href);
    const label = text(item.label);
    return href && label ? [{ href, label, rel: text(item.rel) }] : [];
  }) : [];
  return {
    receiptId: text(response.id),
    receiptTitle: text(response.title),
    receiptStatus: text(response.status),
    receiptVersion: integer(response.version),
    submissionSummary: text(response.summary),
    submittedItems: {
      requestId: text(submitted.requestId),
      submittedAt: text(submitted.submittedAt),
      submissionDigest: text(submitted.submissionDigest),
      status: text(submitted.status),
      retentionNotice: text(submitted.retentionNotice),
      answerCount: integer(submitted.answerCount) ?? answers.length,
      attachmentCount: integer(submitted.attachmentCount) ?? attachments.length,
      publicationScope: text(consent?.scope ?? consent?.publicationScope),
    },
    links,
  };
}
