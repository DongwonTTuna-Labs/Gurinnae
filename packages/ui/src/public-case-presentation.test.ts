import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const publicShell = readFileSync(
  new URL("./components/chrome/PublicShell.svelte", import.meta.url),
  "utf8",
);
const evidenceRows = readFileSync(
  new URL("./components/sections/PublicEvidenceRows.svelte", import.meta.url),
  "utf8",
);
const screenPage = readFileSync(
  new URL("./components/ScreenPage.svelte", import.meta.url),
  "utf8",
);

describe("PUB-004 closed presentation wiring", () => {
  it("keeps the detail lead order and the existing single heading hook", () => {
    expect(publicShell.indexOf("<Breadcrumb")).toBeLessThan(
      publicShell.indexOf('class="public-case-meta"'),
    );
    expect(publicShell.indexOf('class="public-case-meta"')).toBeLessThan(
      publicShell.indexOf("<h1"),
    );
    expect(publicShell.indexOf("<h1")).toBeLessThan(
      publicShell.indexOf('class="public-case-stats"'),
    );
    expect(publicShell.match(/<h1\b/gu)).toHaveLength(1);
    expect(publicShell).toContain("data-testid={projection.focus.heading}");
    expect(publicShell).toContain("runtime.publicCaseLead?.nonConclusion");
  });

  it("renders only approved evidence metadata and secures the original link", () => {
    for (const field of [
      "documentTitle",
      "publisher",
      "publishedAt",
      "sourceUrl",
      "pageAnchor",
    ]) {
      expect(evidenceRows).toContain(`item.${field}`);
    }
    expect(evidenceRows).toContain('target="_blank"');
    expect(evidenceRows).toContain('rel="noopener noreferrer"');
    expect(evidenceRows).not.toMatch(
      /contentSha256|sourceLocator|publicExcerpt|restriction|evidenceType/u,
    );
  });

  it("uses the validated SEO envelope only for PUB-004", () => {
    expect(screenPage).toContain(
      'screen.id === "PUB-004" ? runtime.publicSeo : undefined',
    );
    expect(screenPage).toContain('<link rel="canonical"');
    expect(screenPage).toContain('<meta name="robots"');
  });
});
