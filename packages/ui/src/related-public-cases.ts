import type { ProjectionValue } from "./projection-value";
import { projectionScalarText } from "./projection-value";
import type { RowSelectionNavigationOption } from "./row-selection-navigation";
import type { ScreenSectionProjection } from "./screen-projection";

export type RelatedPublicCase = Readonly<{
  title: string;
  status: string;
  href: string;
}>;

const publicCasePath = /^\/cases\/[A-Za-z0-9._~-]+\/?$/u;
const safeCaseSlug = /^[A-Za-z0-9._~-]+$/u;

/**
 * Reduce PUB-012's typed projection to the only public case fields the
 * browser may render. DTO summaries, internal signal counts and unverified
 * destinations deliberately have no path through this boundary.
 */
export function buildRelatedPublicCases(
  projection: ScreenSectionProjection | undefined,
  verifiedDestinations: readonly RowSelectionNavigationOption[] = [],
): readonly RelatedPublicCase[] {
  if (projection?.screenId !== "PUB-012" || projection.sectionId !== "related")
    return [];

  const relatedCases = projection.fields.find(
    (field) => field.name === "relatedCases" && field.known,
  )?.value;
  if (!isList(relatedCases)) return [];

  const verifiedHrefs = new Set(
    verifiedDestinations.flatMap(({ href }) =>
      isPublicCasePath(href) ? [href] : [],
    ),
  );

  return relatedCases.items.flatMap((item) => {
    if (!isRecord(item)) return [];
    const titleValue = recordString(item, "title");
    const statusValue = recordString(item, "publicState");
    if (titleValue === null || statusValue === null) return [];

    const href = relatedCaseHref({
      slug: recordString(item, "slug"),
      projectedHref: recordString(item, "href"),
      verifiedHrefs,
    });
    if (href === null) return [];

    const title = projectionScalarText("title", titleValue);
    const status = projectionScalarText("publicState", statusValue);
    return title && status ? [{ title, status, href }] : [];
  });
}

function relatedCaseHref(input: {
  slug: string | null;
  projectedHref: string | null;
  verifiedHrefs: ReadonlySet<string>;
}): string | null {
  const slug = input.slug?.trim();
  if (slug && slug.length <= 128 && safeCaseSlug.test(slug))
    return `/cases/${encodeURIComponent(slug)}`;

  const projectedHref = input.projectedHref?.trim();
  return projectedHref &&
    isPublicCasePath(projectedHref) &&
    input.verifiedHrefs.has(projectedHref)
    ? projectedHref
    : null;
}

function isPublicCasePath(value: string): boolean {
  return publicCasePath.test(value);
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
