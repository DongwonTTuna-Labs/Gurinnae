import { describe, expect, it } from "vitest";
import * as operations from "./generated/sdk.gen";

describe("public generated client", () => {
  it("exports every public operation exactly once", () => {
    expect(Object.keys(operations).sort()).toHaveLength(41);
  });
});
