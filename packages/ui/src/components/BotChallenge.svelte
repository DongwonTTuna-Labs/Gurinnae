<script lang="ts">
import { onMount } from "svelte";
import type { BotChallengeRuntime } from "../index";

type TurnstileApi = {
  render(
    container: HTMLElement,
    options: {
      sitekey: string;
      action: string;
      callback: (token: string) => void;
      "expired-callback": () => void;
      "error-callback": () => boolean;
    },
  ): string;
  remove(widgetId: string): void;
  reset(widgetId: string): void;
};

let turnstileLoader: Promise<TurnstileApi> | undefined;

let {
  config,
  action,
  onProof,
}: {
  config?: BotChallengeRuntime | undefined;
  action: string;
  onProof: (proof: string) => void;
} = $props();

let container = $state<HTMLDivElement>();
let widgetId = $state<string>();
let proof = $state("");
let status = $state("자동 제출 방지 검증을 준비하고 있습니다.");
let failed = $state(false);
let active = false;

function publish(value: string) {
  proof = value;
  onProof(value);
}

function syntheticProof() {
  publish(
    JSON.stringify({
      provider: "SYNTHETIC_TEST",
      token: globalThis.crypto.randomUUID(),
      action,
      issuedAt: Math.floor(Date.now() / 1000),
    }),
  );
  status = "테스트 환경의 자동 제출 방지 검증을 완료했습니다.";
}

function reset() {
  publish("");
  failed = false;
  status = "자동 제출 방지 검증을 다시 진행합니다.";
  const turnstile = currentTurnstile();
  if (widgetId && turnstile) {
    turnstile.reset(widgetId);
  } else {
    void renderTurnstile();
  }
}

onMount(() => {
  active = true;
  if (!config) {
    failed = true;
    status = "자동 제출 방지 검증이 구성되지 않았습니다.";
    return;
  }
  if (config.provider === "SYNTHETIC_TEST") {
    syntheticProof();
    return;
  }
  void renderTurnstile();
  return () => {
    active = false;
    const turnstile = currentTurnstile();
    if (widgetId && turnstile) turnstile.remove(widgetId);
    widgetId = undefined;
  };
});

async function renderTurnstile() {
  if (!active || !config || config.provider !== "TURNSTILE" || !container)
    return;
  try {
    const turnstile = await loadTurnstile();
    if (!active || !container) return;
    widgetId = turnstile.render(container, {
      sitekey: config.siteKey,
      action,
      callback: (token) => {
        publish(JSON.stringify({ provider: "TURNSTILE", token, action }));
        failed = false;
        status = "자동 제출 방지 검증을 완료했습니다.";
      },
      "expired-callback": () => {
        publish("");
        failed = true;
        status = "검증이 만료되었습니다. 다시 확인해 주세요.";
      },
      "error-callback": () => {
        publish("");
        failed = true;
        status = "검증을 완료하지 못했습니다. 다시 시도해 주세요.";
        return true;
      },
    });
  } catch {
    if (!active) return;
    publish("");
    failed = true;
    status = "검증 서비스를 불러오지 못했습니다. 다시 시도해 주세요.";
  }
}

function loadTurnstile(): Promise<TurnstileApi> {
  const current = currentTurnstile();
  if (current) return Promise.resolve(current);
  if (turnstileLoader) return turnstileLoader;
  document
    .querySelector<HTMLScriptElement>('script[data-gurine-turnstile="true"]')
    ?.remove();
  const pending = new Promise<TurnstileApi>((resolve, reject) => {
    const script = document.createElement("script");
    const loaded = () =>
      currentTurnstile()
        ? resolve(currentTurnstile() as TurnstileApi)
        : reject(new Error("Turnstile API is unavailable"));
    script.addEventListener("load", loaded, { once: true });
    script.addEventListener(
      "error",
      () => reject(new Error("Turnstile load failed")),
      {
        once: true,
      },
    );
    script.src =
      "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
    script.async = true;
    script.defer = true;
    script.dataset.gurineTurnstile = "true";
    document.head.append(script);
  });
  turnstileLoader = pending.catch((error) => {
    turnstileLoader = undefined;
    throw error;
  });
  return turnstileLoader;
}

function currentTurnstile(): TurnstileApi | undefined {
  return (window as Window & { turnstile?: TurnstileApi }).turnstile;
}
</script>

<div class="bot-challenge" data-testid="bot-challenge">
  <span class="challenge-label">자동 제출 방지 확인 (필수)</span>
  <div bind:this={container}></div>
  <input type="hidden" name="abuseProof" value={proof} />
  <p class:challenge-error={failed} role="status" aria-live="polite">{status}</p>
  {#if failed && config}
    <button class="secondary-button" type="button" onclick={reset}>검증 다시 시도</button>
  {/if}
</div>

<style>
  .bot-challenge {
    display: grid;
    gap: 0.55rem;
    min-width: 0;
  }
  .challenge-label {
    font-weight: 700;
  }
  .bot-challenge p {
    margin: 0;
  }
  .challenge-error {
    color: var(--color-danger, #9f1239);
  }
  button {
    min-height: 44px;
    justify-self: start;
  }
</style>
