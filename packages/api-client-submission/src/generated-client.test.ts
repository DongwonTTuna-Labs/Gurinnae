import { describe, expect, it } from "vitest";
import * as operations from "./generated/sdk.gen";

describe("submission generated client", () => {
  it("exports every submission operation exactly once", () => {
    const names = Object.keys(operations).sort();
    // The v13 base surface (34) is extended by the reviewed addendum
    // operations (8); generated output must contain both sets exactly once.
    expect(names).toHaveLength(42);
    expect(new Set(names).size).toBe(names.length);
  });
});
