import { describe, expect, it } from "vitest";
import * as operations from "./generated/sdk.gen";

describe("control generated client", () => {
  it("exports every control operation exactly once", () => {
    expect(Object.keys(operations).sort()).toHaveLength(131);
  });
});
