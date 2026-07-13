import type { ScreenRuntime } from "@gurine/ui";

export function publicRuntimeState(input: {
  errors: number;
  resolved: number;
  hasData: boolean;
}): ScreenRuntime["state"] {
  if (input.errors > 0) return input.resolved > 0 ? "partial" : "error";
  return input.hasData ? "success" : "empty";
}
