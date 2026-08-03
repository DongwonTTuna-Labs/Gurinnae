import type { ScreenRuntime } from "./index";

const SEARCH_DOWNLOAD_HIDDEN_STATES: readonly ScreenRuntime["state"][] = [
  "awaiting-query",
  "error",
  "server-error",
];

export function publicSearchDownloadVisible(
  screenId: string,
  interactionKind: string,
  resultCount: number,
  runtimeState: ScreenRuntime["state"],
): boolean {
  if (screenId !== "PUB-002" || interactionKind !== "DOWNLOAD") return true;
  return (
    resultCount > 0 && !SEARCH_DOWNLOAD_HIDDEN_STATES.includes(runtimeState)
  );
}
