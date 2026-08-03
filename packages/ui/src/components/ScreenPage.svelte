<script lang="ts">
import type { ScreenRuntime, ScreenViewModel } from "../index";
import { surfaceForScreen } from "../screen-chrome";
import { typedScreenViewModel } from "../screen-contract";
import { projectScreen } from "../screen-projection";
import AuthShell from "./chrome/AuthShell.svelte";
import InternalShell from "./chrome/InternalShell.svelte";
import PublicShell from "./chrome/PublicShell.svelte";
import ResponseShell from "./chrome/ResponseShell.svelte";

let { screen, runtime }: { screen: ScreenViewModel; runtime: ScreenRuntime } =
  $props();
const contract = $derived(typedScreenViewModel(screen));
const projection = $derived(projectScreen(screen, runtime));
const surface = $derived(surfaceForScreen(screen.id));
const publicSeo = $derived(
  screen.id === "PUB-004" ? runtime.publicSeo : undefined,
);
</script>

<svelte:head>
  <title>{publicSeo?.title ?? `${screen.title} · 구린네`}</title>
  <meta name="description" content={publicSeo?.description ?? `${screen.title} — 근거와 한계를 함께 확인합니다.`} />
  {#if publicSeo}
    <link rel="canonical" href={publicSeo.canonicalUrl} />
    <meta name="robots" content={publicSeo.robots} />
  {/if}
</svelte:head>

{#if surface === "public"}
  <PublicShell {screen} {runtime} {contract} {projection} />
{:else if surface === "response"}
  <ResponseShell {screen} {runtime} {contract} {projection} />
{:else if surface === "auth"}
  <AuthShell {screen} {runtime} {contract} {projection} />
{:else}
  <InternalShell {screen} {runtime} {contract} {projection} />
{/if}
