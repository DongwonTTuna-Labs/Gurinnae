import { describe, expect, it } from "vitest";
import { attachmentOptionLabel } from "./attachment-option";

describe("attachment option labels", () => {
  it("keeps missing-filename choices distinct without exposing full UUIDs", () => {
    const first = "aaaaaaaa-0000-4000-8000-000000000001";
    const second = "aaaaaaaa-0000-4000-8000-000000000002";

    const labels = [
      attachmentOptionLabel({ id: first }, 0),
      attachmentOptionLabel({ id: second }, 1),
    ];

    expect(labels).toEqual([
      "첨부 파일 1 · aaaaaaaa",
      "첨부 파일 2 · aaaaaaaa",
    ]);
    expect(new Set(labels).size).toBe(2);
    expect(labels.join(" ")).not.toContain(first);
    expect(labels.join(" ")).not.toContain(second);
  });

  it("uses an available filename and rejects invalid ordering metadata", () => {
    expect(
      attachmentOptionLabel({ id: "attachment-1", filename: "근거.pdf" }, 0),
    ).toBe("근거.pdf");
    expect(() => attachmentOptionLabel({ id: "attachment-1" }, -1)).toThrow(
      "첨부 순서 계약 위반",
    );
  });
});
