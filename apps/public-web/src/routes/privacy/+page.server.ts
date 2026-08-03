import { redirect } from "@sveltejs/kit";
import { getPrivacyRequestStatus } from "$lib/server/privacy-request-bff";
import { loadScreen, screenActions } from "$lib/server/screen";
import { withoutToken } from "$lib/server/screen-helpers";
import { screen } from "./screen";

export const load = async (event) => {
  if (event.url.searchParams.has("token")) {
    event.setHeaders({
      "cache-control": "no-store",
      "referrer-policy": "no-referrer",
    });
    throw redirect(
      303,
      withoutToken(event.url, "보안 링크를 사용할 수 없습니다."),
    );
  }
  const page = await loadScreen(event, screen);
  const status = await getPrivacyRequestStatus(event);
  return {
    ...page,
    runtime: {
      ...page.runtime,
      ...(status.state === "READY"
        ? {
            privacyRequestStatus: {
              loadState: "READY" as const,
              ...status.status,
            },
          }
        : status.state === "UNAVAILABLE"
          ? { privacyRequestStatus: { loadState: "UNAVAILABLE" as const } }
          : {}),
    },
  };
};
export const actions = screenActions(screen);
