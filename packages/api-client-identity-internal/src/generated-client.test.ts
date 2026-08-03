import { describe, expect, it } from "vitest";
import * as operations from "./generated/sdk.gen";

describe("identity internal generated client", () => {
  it("exports every private identity operation exactly once", () => {
    expect(Object.keys(operations).sort()).toHaveLength(9);
  });
});
