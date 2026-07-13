import { loadScreen, screenActions } from "$lib/server/screen";
import { screen } from "./screen";

export const load = async (event) => loadScreen(event, screen);
export const actions = screenActions(screen);
