import { describe, expect, it } from "vitest";
import * as operations from "./generated/sdk.gen";

describe("submission generated client", () => {
  it("exports every submission operation exactly once", () => {
    expect(Object.keys(operations).sort()).toHaveLength(34);
  });
});
