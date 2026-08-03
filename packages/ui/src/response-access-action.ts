import type { ScreenRuntime, ScreenViewModel } from "./index";
import { localActionHref } from "./local-actions";

export type ResponseAccessPrimaryAction = {
  id: string;
  label: string;
  href: string;
};

export function responseAccessPrimaryAction(
  screen: ScreenViewModel,
  runtime: ScreenRuntime,
  primaryActionId: string | null,
): ResponseAccessPrimaryAction | undefined {
  if (
    screen.id !== "RSP-001" ||
    runtime.state !== "unauthenticated" ||
    runtime.errors.length > 0 ||
    !primaryActionId
  )
    return undefined;

  const action = screen.actions.find(({ id }) => id === primaryActionId);
  if (action?.interaction_kind !== "NAVIGATION") return undefined;
  const href = localActionHref(screen, runtime, action);
  return href ? { id: action.id, label: action.label, href } : undefined;
}
