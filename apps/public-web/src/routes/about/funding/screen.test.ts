import { describe, expect, it } from "vitest";
import { screen } from "./screen";

describe("PUB-023 public copy", () => {
  it("uses Korean public labels instead of internal funding terms", () => {
    const copy = screen.sections.map((section) => section.purpose).join("\n");

    expect(copy).toContain("후원·지원금·조직용 서비스");
    expect(copy).toContain("기간별 투명성 보고서");
    expect(copy).not.toMatch(/grant|API\/SaaS|transparency report/iu);
    expect(
      screen.dataOperations.find(
        (operation) => operation.operation_id === "downloadTransparencyReport",
      ),
    ).toMatchObject({
      method: "GET",
      path: "/v1/transparency-reports/{reportId}/download",
      blocking: false,
    });
    expect(screen.actions[0]).toMatchObject({
      id: "download-report",
      request_binding: {
        reportId: "listTransparencyReports.items[].id",
      },
      href_binding: {
        source: "listTransparencyReports.items[].href",
        must_equal: "/v1/transparency-reports/{reportId}/download",
      },
    });
  });
});
