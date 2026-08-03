import { expect, type Locator } from "@playwright/test";

export async function expectNativeFormValidity(form: Locator): Promise<void> {
  const invalidControls = await form.evaluate((element) => {
    if (!(element instanceof HTMLFormElement)) return ["not-a-form"];
    return Array.from(element.querySelectorAll(":invalid")).map(
      (control) =>
        `${control.getAttribute("name") ?? control.tagName}: ${control.getAttribute("type") ?? ""}`,
    );
  });
  expect(invalidControls).toEqual([]);
}
