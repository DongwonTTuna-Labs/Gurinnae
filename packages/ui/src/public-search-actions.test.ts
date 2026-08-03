import { describe, expect, it } from "vitest";
import { publicSearchDownloadVisible } from "./public-search-actions";

describe("public search result-bound actions", () => {
  it("hides downloads until at least one validated result exists", () => {
    expect(publicSearchDownloadVisible("PUB-002", "DOWNLOAD", 0, "empty")).toBe(
      false,
    );
    expect(
      publicSearchDownloadVisible("PUB-002", "DOWNLOAD", 1, "success"),
    ).toBe(true);
  });

  it("fails closed in pre-query and error states even if stale rows exist", () => {
    for (const state of ["awaiting-query", "error", "server-error"] as const) {
      expect(publicSearchDownloadVisible("PUB-002", "DOWNLOAD", 1, state)).toBe(
        false,
      );
    }
  });

  it("does not affect other search actions or screens", () => {
    expect(
      publicSearchDownloadVisible("PUB-002", "COMMAND", 0, "awaiting-query"),
    ).toBe(true);
    expect(publicSearchDownloadVisible("OPS-004", "DOWNLOAD", 0, "error")).toBe(
      true,
    );
  });
});
