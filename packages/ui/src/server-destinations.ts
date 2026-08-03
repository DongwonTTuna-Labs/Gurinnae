import type { ScreenRuntime, ScreenViewModel } from "./index";
import { localActionHref } from "./local-actions";

/**
 * Build the closed navigation envelope on the server.  Components never
 * infer routes from operation DTOs; every action receives either an
 * authority-declared destination or remains unavailable.
 */
export function serverActionDestinations(
  screen: ScreenViewModel,
  pathname: string,
): Readonly<Record<string, string>> {
  const runtime: ScreenRuntime = {
    state: "success",
    pathname,
    data: {},
    errors: [],
    forms: {},
  };
  return Object.fromEntries(
    screen.actions.flatMap((action) => {
      const href = localActionHref(screen, runtime, action);
      return href ? [[action.id, href] as const] : [];
    }),
  );
}
