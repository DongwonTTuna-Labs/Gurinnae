import type { ScreenRuntime } from "@gurine/ui";

export function responseRuntimeState(input: {
  authenticated: boolean;
  errors: number;
  resolved: number;
}): ScreenRuntime["state"] {
  if (!input.authenticated) return "unauthenticated";
  if (input.errors === 0) return "success";
  return input.resolved > 0 ? "partial" : "error";
}
