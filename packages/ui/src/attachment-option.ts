export type AttachmentOption = Readonly<{ id: string; filename?: string }>;

export function attachmentOptionLabel(
  attachment: AttachmentOption,
  index: number,
): string {
  if (!Number.isInteger(index) || index < 0) {
    throw new Error(`첨부 순서 계약 위반: ${index}`);
  }
  if (!attachment.id || attachment.id.trim() !== attachment.id) {
    throw new Error("첨부 식별자 계약 위반");
  }
  return (
    attachment.filename ??
    `첨부 파일 ${index + 1} · ${attachment.id.slice(0, 8)}`
  );
}
