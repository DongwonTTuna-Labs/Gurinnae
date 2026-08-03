export type PublicStatusNoticeKind = "INTERPRETATION" | "NON_CONCLUSION";

export const PUBLIC_SECTION_NON_CONCLUSION_NOTICE =
  "이상 징후 기록이며 위법·부패의 확정이 아님";

/** Browser-safe legal context kept adjacent to a public status. */
export type PublicStatusNotice = Readonly<{
  kind: PublicStatusNoticeKind;
  label: "비확정 고지" | "상태 해석";
  text: string;
}>;

export type PublicStatusContextField = Readonly<{
  label: string;
  text: string;
}>;

/** Closed subject/status binding for a public detail notice. */
export type PublicDetailStatusContext = Readonly<{
  subject: PublicStatusContextField;
  status?: PublicStatusContextField;
  notice: PublicStatusNotice;
}>;

export function publicStatusNotice(
  kind: PublicStatusNoticeKind,
  text: string,
): PublicStatusNotice {
  const normalized = text.trim();
  if (!normalized) throw new Error(`공개 상태 고지 누락: ${kind}`);
  return {
    kind,
    label: kind === "NON_CONCLUSION" ? "비확정 고지" : "상태 해석",
    text: normalized,
  };
}

export function publicSectionNonConclusionNotice(): PublicStatusNotice {
  return publicStatusNotice(
    "NON_CONCLUSION",
    PUBLIC_SECTION_NON_CONCLUSION_NOTICE,
  );
}

export function publicDetailStatusContext(
  subject: PublicStatusContextField,
  status: PublicStatusContextField | undefined,
  notice: PublicStatusNotice,
): PublicDetailStatusContext {
  return {
    subject: normalizedContextField(subject, "대상"),
    ...(status ? { status: normalizedContextField(status, "상태") } : {}),
    notice,
  };
}

function normalizedContextField(
  field: PublicStatusContextField,
  kind: string,
): PublicStatusContextField {
  const label = field.label.trim();
  const text = field.text.trim();
  if (!label || !text) throw new Error(`공개 ${kind} 연결 누락`);
  return { label, text };
}
