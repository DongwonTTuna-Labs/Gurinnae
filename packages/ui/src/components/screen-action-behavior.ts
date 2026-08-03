import type { ScreenRuntime, ScreenViewModel } from "../index";
import { localActionHref } from "../local-actions";
import { projectionScalarText } from "../projection-value";

type ScreenAction = ScreenViewModel["actions"][number];

export function supportsLocalCommand(
  screen: ScreenViewModel,
  runtime: ScreenRuntime,
  action: ScreenAction,
): boolean {
  if (action.id.startsWith("copy-")) return true;
  if (["clear", "retry", "discard-change", "discard-local"].includes(action.id))
    return true;
  if (action.id === "open-evidence")
    return localActionHref(screen, runtime, action) !== undefined;
  return false;
}

export function runLocalCommand(
  screen: ScreenViewModel,
  runtime: ScreenRuntime,
  action: ScreenAction,
): void {
  if (typeof window === "undefined") return;
  if (action.id.startsWith("copy-")) {
    const evidence = runtime.projection
      ? Object.values(runtime.projection.sections)
          .flatMap((section) => Object.entries(section.fields))
          .filter(([, field]) => field.known && field.value !== null)
          .map(
            ([name, field]) =>
              `${projectionScalarText(name, field.value) ?? "구조화 자료"} (${field.source})`,
          )
          .join("\n")
      : "확인 가능한 근거가 없습니다.";
    void navigator.clipboard.writeText(
      `${screen.title}\n${window.location.href}\n\n근거·식별자\n${evidence}`,
    );
    return;
  }
  if (action.id === "clear") {
    window.location.assign(runtime.pathname ?? screen.route);
    return;
  }
  if (action.id === "retry" || action.id === "discard-change") {
    window.location.reload();
    return;
  }
  if (action.id === "discard-local") {
    const prefix = `gurine:${screen.id}:`;
    for (const storage of [window.sessionStorage, window.localStorage]) {
      for (let index = storage.length - 1; index >= 0; index -= 1) {
        const key = storage.key(index);
        if (key?.startsWith(prefix)) storage.removeItem(key);
      }
    }
    window.location.assign("/auth/sign-in");
    return;
  }
  if (action.id === "open-evidence") {
    const destination = localActionHref(screen, runtime, action);
    if (destination) window.location.assign(destination);
  }
}

export function downloadHref(
  screen: ScreenViewModel,
  runtime: ScreenRuntime,
  action: ScreenAction,
): string | undefined {
  if (screen.id === "PUB-021" && action.id === "download-openapi") {
    return "/api/openapi.json";
  }
  const encoded = runtime.downloads?.[action.id];
  return encoded
    ? `data:${encoded.mime};base64,${encoded.binary}`
    : localActionHref(screen, runtime, action);
}

export function downloadName(
  screen: ScreenViewModel,
  runtime: ScreenRuntime,
  action: ScreenAction,
): string | undefined {
  const encoded = runtime.downloads?.[action.id];
  return encoded
    ? `${screen.id.toLowerCase()}-${action.id}.${encoded.extension}`
    : undefined;
}
