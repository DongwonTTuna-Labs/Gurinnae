import { describe, expect, it } from "vitest";
import { packageName } from "./index";

describe("shared configuration package", () => {
  it("has a stable workspace identity", () => {
    expect(packageName).toBe("@gurine/config");
  });
});
