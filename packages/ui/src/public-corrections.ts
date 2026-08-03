import type { ProjectionValue } from "./projection-value";
import { projectionScalarText } from "./projection-value";
import {
  type PublicStatusNotice,
  publicStatusNotice,
} from "./public-status-notice";
import type { ScreenSectionProjection } from "./screen-projection";

export type PublicCorrectionRow = Readonly<{
  key: string;
  summary: string;
  reason: string;
  status: string;
  publishedAt: string;
  notice: PublicStatusNotice;
  href: string;
}>;

const correctionPath = /^\/corrections\/[A-Za-z0-9._~-]+\/?$/u;
const safeIdentifier = /^[A-Za-z0-9._~-]+$/u;

export function buildHomeCorrections(
  projection: ScreenSectionProjection | undefined,
): readonly PublicCorrectionRow[] {
  if (
    projection?.screenId !== "PUB-001" ||
    projection.sectionId !== "corrections"
  )
    return [];
  const value = projection.fields.find(
    (field) => field.name === "items" && field.known,
  )?.value;
  if (!isList(value)) return [];

  return value.items.flatMap((item) => {
    if (!isRecord(item)) return [];
    const id = recordString(item, "id");
    const summaryValue = recordString(item, "summary");
    const reasonValue = recordString(item, "reason");
    const statusValue = recordString(item, "publicState");
    const publishedAtValue = recordString(item, "publishedAt");
    const noticeValue = recordString(item, "nonConclusion");
    if (!summaryValue || !reasonValue || !statusValue || !publishedAtValue)
      return [];
    if (!noticeValue) throw new Error("홈 정정 기록 비확정 고지 계약 누락");
    const href = correctionHref(id, recordString(item, "href"));
    if (!href) return [];
    const summary = projectionScalarText("summary", summaryValue);
    const reason = projectionScalarText("reason", reasonValue);
    const status = projectionScalarText("publicState", statusValue);
    const publishedAt = projectionScalarText("publishedAt", publishedAtValue);
    return summary && reason && status && publishedAt
      ? [
          {
            key: href,
            summary,
            reason,
            status,
            publishedAt,
            notice: publicStatusNotice("NON_CONCLUSION", noticeValue),
            href,
          },
        ]
      : [];
  });
}

function correctionHref(id: string | null, href: string | null): string | null {
  const normalizedId = id?.trim();
  if (
    normalizedId &&
    normalizedId.length <= 128 &&
    safeIdentifier.test(normalizedId)
  )
    return `/corrections/${encodeURIComponent(normalizedId)}`;
  const normalizedHref = href?.trim();
  return normalizedHref && correctionPath.test(normalizedHref)
    ? normalizedHref
    : null;
}

function recordString(
  value: Extract<ProjectionValue, { kind: "record" }>,
  name: string,
): string | null {
  const entry = value.entries.find((candidate) => candidate.name === name);
  return typeof entry?.value === "string" ? entry.value : null;
}

function isList(
  value: ProjectionValue | null | undefined,
): value is Extract<ProjectionValue, { kind: "list" }> {
  return typeof value === "object" && value?.kind === "list";
}

function isRecord(
  value: ProjectionValue,
): value is Extract<ProjectionValue, { kind: "record" }> {
  return typeof value === "object" && value.kind === "record";
}
