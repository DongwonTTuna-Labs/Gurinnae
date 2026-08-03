import { redirect } from "@sveltejs/kit";
import { loadScreen, screenActions } from "$lib/server/screen";
import { screen } from "./screen";

export const load = async (event) => {
  if (event.url.searchParams.has("token")) {
    event.setHeaders({ "cache-control": "no-store" });
    throw redirect(
      303,
      `${screen.route}?${new URLSearchParams({ notice: "보안 링크를 사용할 수 없습니다." })}`,
    );
  }
  return loadScreen(event, screen);
};
export const actions = screenActions(screen);
