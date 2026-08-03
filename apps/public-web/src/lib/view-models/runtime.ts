import type { ScreenRuntime } from "@gurine/ui";

export function publicRuntimeState(input: {
  errors: number;
  resolved: number;
  hasData: boolean;
  invalidFilter?: boolean;
}): ScreenRuntime["state"] {
  if (input.invalidFilter) return "invalid-filter";
  if (input.errors > 0) return input.resolved > 0 ? "partial" : "error";
  return input.hasData ? "success" : "empty";
}
