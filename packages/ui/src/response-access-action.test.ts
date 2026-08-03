import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import type { ScreenRuntime, ScreenViewModel } from "./index";
import { responseAccessPrimaryAction } from "./response-access-action";

const screen: ScreenViewModel = {
  id: "RSP-001",
  title: "소명 요청 확인",
  route: "/respond/access",
  archetype: "GUIDED_FORM",
  sections: [],
  actions: [
    {
      id: "continue",
      label: "요청 내용 보기",
      interaction_kind: "NAVIGATION",
    },
  ],
  states: ["unauthenticated"],
  dataOperations: [],
};

const runtime: ScreenRuntime = {
  state: "unauthenticated",
  pathname: "/respond/access",
  data: {},
  errors: [],
  forms: {},
};

describe("RSP-001 initial access primary action", () => {
  it("keeps the declared continue action wired to the response overview", () => {
    expect(responseAccessPrimaryAction(screen, runtime, "continue")).toEqual({
      id: "continue",
      label: "요청 내용 보기",
      href: "/respond/overview",
    });
  });

  it("renders one primary hook without restoring the protected action panel", () => {
    const guidance = readFileSync(
      new URL(
        "./components/screen/UnauthenticatedGuidance.svelte",
        import.meta.url,
      ),
      "utf8",
    );
    const responseShell = readFileSync(
      new URL("./components/chrome/ResponseShell.svelte", import.meta.url),
      "utf8",
    );
    expect(guidance.match(/data-action-id=\{action\.id\}/gu)).toHaveLength(1);
    expect(responseShell).toContain("action={initialAccessAction}");
    expect(responseShell).toContain("<UnauthenticatedSectionOutline");
  });

  it("fails closed for error states and non-navigation actions", () => {
    expect(
      responseAccessPrimaryAction(
        screen,
        { ...runtime, errors: ["보안 링크 확인 실패"] },
        "continue",
      ),
    ).toBeUndefined();
    expect(
      responseAccessPrimaryAction(
        {
          ...screen,
          actions: [
            {
              id: "continue",
              label: "요청 내용 보기",
              interaction_kind: "COMMAND",
            },
          ],
        },
        runtime,
        "continue",
      ),
    ).toBeUndefined();
  });
});
