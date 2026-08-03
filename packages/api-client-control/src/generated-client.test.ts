import { describe, expect, it } from "vitest";
import * as operations from "./generated/sdk.gen";

describe("control generated client", () => {
  it("exports every control operation exactly once", () => {
    const names = Object.keys(operations).sort();
    // The v13 base surface (131) is extended by the reviewed addendum
    // operations (36); generated output must contain both sets exactly once.
    expect(names).toHaveLength(167);
    expect(new Set(names).size).toBe(names.length);
  });
});
