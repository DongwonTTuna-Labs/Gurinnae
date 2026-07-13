import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const css = readFileSync(
  new URL("./styles/styles.css", import.meta.url),
  "utf8",
);

describe("shared UI accessibility baseline", () => {
  it("keeps keyboard focus and skip navigation visible", () => {
    expect(css).toContain(".skip-link:focus");
    expect(css).toContain(":focus-visible");
  });

  it("respects reduced motion", () => {
    expect(css).toContain("prefers-reduced-motion: reduce");
  });
});
