import { readdirSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const aggregator = readFileSync(
  new URL("./styles/styles.css", import.meta.url),
  "utf8",
);
const styleDirectory = new URL("./styles/", import.meta.url);
const imports = [...aggregator.matchAll(/@import "\.\/([^"]+)";/gu)].map(
  (match) => {
    const filename = match[1];
    if (!filename) throw new Error("stylesheet import is missing a filename");
    return filename;
  },
);
const globalCss = imports
  .map((filename) => readFileSync(new URL(filename, styleDirectory), "utf8"))
  .join("");

function readSvelteSources(directory: URL): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    if (entry.isDirectory())
      return readSvelteSources(new URL(`${entry.name}/`, directory));
    if (!entry.isFile() || !entry.name.endsWith(".svelte")) return [];
    return [readFileSync(new URL(entry.name, directory), "utf8")];
  });
}

const svelteSources = readSvelteSources(
  new URL("./components/", import.meta.url),
);
const componentCss = svelteSources
  .flatMap((source) =>
    [...source.matchAll(/<style(?:\s[^>]*)?>([\s\S]*?)<\/style>/gu)].map(
      (match) => match[1] ?? "",
    ),
  )
  .join("");
const css = `${globalCss}\n${componentCss}`;
const operationData = readFileSync(
  new URL("./components/OperationData.svelte", import.meta.url),
  "utf8",
);
const screenHeading = readFileSync(
  new URL("./components/screen/ScreenHeading.svelte", import.meta.url),
  "utf8",
);
const sectionHeading = readFileSync(
  new URL("./components/sections/SectionHeading.svelte", import.meta.url),
  "utf8",
);
const structuredContent = readFileSync(
  new URL(
    "./components/sections/StructuredContentSection.svelte",
    import.meta.url,
  ),
  "utf8",
);
const semanticSection = readFileSync(
  new URL("./components/sections/SemanticSection.svelte", import.meta.url),
  "utf8",
);
const claimWorkbench = readFileSync(
  new URL("./components/sections/ClaimWorkbench.svelte", import.meta.url),
  "utf8",
);
const dataModule = readFileSync(new URL("./data.ts", import.meta.url), "utf8");

describe("shared UI accessibility baseline", () => {
  it("keeps only tokens, base, and shared primitives global", () => {
    expect(imports).toEqual([
      "00-tokens.css",
      "10-base.css",
      "50-primitives.css",
    ]);
    for (const selector of [
      ".public-header",
      ".public-main",
      ".internal-shell",
      ".workspace-grid",
      ".form-shell",
      ".footer",
      ".hero",
    ]) {
      expect(globalCss).not.toContain(selector);
    }
    expect(svelteSources.join("\n")).not.toContain("<style global");
  });

  it("keeps keyboard focus and skip navigation visible", () => {
    expect(css).toContain(".skip-link:focus");
    expect(css).toContain(":focus-visible");
  });

  it("respects reduced motion", () => {
    expect(css).toContain("prefers-reduced-motion: reduce");
  });

  it("keeps journey controls usable at compact widths", () => {
    expect(css).toContain(".decision-button-row");
    expect(css).toContain(".business-health");
    expect(css).toContain(".approval-queue-card");
    expect(css).toContain("@media (max-width: 620px)");
    expect(css).toContain("@media (max-width: 760px)");
  });

  it("enforces the restrained type and decoration scale", () => {
    expect(globalCss).toContain("--text-h1: clamp(1.5rem, 2vw, 1.875rem)");
    expect(globalCss).toContain("--text-meta: 0.75rem");
    expect(globalCss).toContain("--radius-sm: 4px");
    expect(globalCss).toContain("--radius-md: 6px");
    expect(css).not.toMatch(/\b(?:linear|radial|conic)-gradient\(/u);
    expect(css.match(/\bbox-shadow\s*:/gu) ?? []).toHaveLength(1);
    for (const match of css.matchAll(
      /font-size:\s*([0-9]+(?:\.[0-9]+)?)(px|rem)/gu,
    )) {
      const value = Number(match[1]);
      expect(value).toBeGreaterThanOrEqual(match[2] === "px" ? 12 : 0.75);
    }
  });

  it("removes the home hero without weakening its safety statement", () => {
    expect(screenHeading).toContain(">공개 기록 대장</h1>");
    expect(screenHeading).toContain("반복 계약");
    expect(screenHeading).toContain("위법·비리를 의미하지 않습니다");
    expect(screenHeading).not.toContain('class="hero"');
    expect(screenHeading).not.toContain(".hero");
  });

  it("does not render operation identifiers as user-facing record titles", () => {
    expect(operationData).not.toContain("{item.operationId}");
    expect(operationData).toContain("기록 {index + 1}");
  });

  it("renders frozen section purpose copy once and at supporting emphasis", () => {
    expect(structuredContent).toContain("sectionCopy !== section.purpose");
    expect(semanticSection).not.toContain(">{section.purpose}</p>");
    expect(claimWorkbench).not.toContain(">{section.purpose}</p>");
    expect(sectionHeading).toContain("font-size: var(--text-meta, 0.75rem)");
  });

  it("filters unknown/raw response keys before a generic record can render", () => {
    expect(dataModule).toContain("displayFieldKeys");
    expect(dataModule).toContain(
      ".filter(([key]) => displayFieldKeys.has(key)",
    );
    expect(dataModule).not.toContain(
      "Object.entries(record).map(([key, value])",
    );
  });
});
