import type { ScreenRuntime } from "@gurine/ui";

export function reviewRuntimeState(
  errors: number,
  resolved: number,
): ScreenRuntime["state"] {
  if (errors === 0) return "success";
  return resolved > 0 ? "partial" : "error";
}
