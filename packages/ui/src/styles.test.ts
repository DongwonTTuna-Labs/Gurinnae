import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const css = readFileSync(
  new URL("./styles/styles.css", import.meta.url),
  "utf8",
);
const operationData = readFileSync(
  new URL("./components/OperationData.svelte", import.meta.url),
  "utf8",
);
const dataModule = readFileSync(new URL("./data.ts", import.meta.url), "utf8");

describe("shared UI accessibility baseline", () => {
  it("keeps keyboard focus and skip navigation visible", () => {
    expect(css).toContain(".skip-link:focus");
    expect(css).toContain(":focus-visible");
  });

  it("respects reduced motion", () => {
    expect(css).toContain("prefers-reduced-motion: reduce");
  });

  it("keeps journey controls usable at compact widths", () => {
    expect(css).toContain(".decision-button-row");
    expect(css).toContain(".health-grid");
    expect(css).toContain(".channel-grid");
    expect(css).toContain("@media (max-width: 620px)");
  });

  it("does not render operation identifiers as user-facing record titles", () => {
    expect(operationData).not.toContain("{item.operationId}");
    expect(operationData).toContain("기록 {index + 1}");
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
