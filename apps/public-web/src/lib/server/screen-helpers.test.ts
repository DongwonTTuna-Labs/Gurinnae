import { describe, expect, it } from "vitest";
import { withoutToken } from "./screen-helpers";

describe("screen URL secret removal", () => {
  it("removes the token and emits a canonical percent-encoded notice", () => {
    const url = new URL(
      "https://public.test/privacy?token=secret&returnTo=%2Bkept#status",
    );

    expect(withoutToken(url, "보안 링크를 사용할 수 없습니다.")).toBe(
      "/privacy?returnTo=%2Bkept&notice=%EB%B3%B4%EC%95%88%20%EB%A7%81%ED%81%AC%EB%A5%BC%20%EC%82%AC%EC%9A%A9%ED%95%A0%20%EC%88%98%20%EC%97%86%EC%8A%B5%EB%8B%88%EB%8B%A4.#status",
    );
  });
});
