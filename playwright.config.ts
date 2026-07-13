import { defineConfig, devices } from "@playwright/test";

const mock = "http://127.0.0.1:29100";

export default defineConfig({
  testDir: "./tests/e2e",
  fullyParallel: true,
  forbidOnly: true,
  retries: 0,
  workers: 4,
  timeout: 60_000,
  expect: {
    timeout: 8_000,
    toHaveScreenshot: { animations: "disabled", maxDiffPixelRatio: 0.002 },
  },
  reporter: [["line"]],
  use: {
    ...devices["Desktop Chrome"],
    locale: "ko-KR",
    timezoneId: "Asia/Seoul",
    colorScheme: "light",
    reducedMotion: "reduce",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
  webServer: [
    {
      command: "MOCK_API_PORT=29100 bun run tests/e2e/support/mock-api.ts",
      url: `${mock}/health/ready`,
      reuseExistingServer: false,
      timeout: 30_000,
    },
    {
      command: `HOST=127.0.0.1 PORT=29101 GURINE_ENV=test ORIGIN=http://127.0.0.1:29101 PUBLIC_BASE_URL=http://127.0.0.1:29101 PUBLIC_API_INTERNAL_URL=${mock} SUBMISSION_API_INTERNAL_URL=${mock} PUBLIC_WEB_SUBMISSION_HMAC_KEY_CURRENT=MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE= SUBMISSION_COOKIE_KEY_CURRENT=GQBTWs9nf7Kq81QWQ95fHNnlF9jwS7ZS8SH92g968+g= bun apps/public-web/build/index.js`,
      url: "http://127.0.0.1:29101/",
      reuseExistingServer: false,
      timeout: 30_000,
    },
    {
      command: `HOST=127.0.0.1 PORT=29102 GURINE_ENV=test ORIGIN=http://127.0.0.1:29102 REVIEW_BASE_URL=http://127.0.0.1:29102 CONTROL_API_INTERNAL_URL=${mock} IDENTITY_API_INTERNAL_URL=${mock} IDENTITY_SERVICE_HMAC_KEY_CURRENT=MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE= SESSION_COOKIE_KEY_CURRENT=DXOSnJXOHeKea+sBprxSKqM7MN4oH31kfcSKsV1OwNE= bun apps/review-console/build/index.js`,
      url: "http://127.0.0.1:29102/auth/sign-in",
      reuseExistingServer: false,
      timeout: 30_000,
    },
    {
      command:
        "HOST=127.0.0.1 PORT=29103 GURINE_ENV=test ORIGIN=http://127.0.0.1:29103 RESPONSE_BASE_URL=http://127.0.0.1:29103 SUBMISSION_COOKIE_KEY_CURRENT=GQBTWs9nf7Kq81QWQ95fHNnlF9jwS7ZS8SH92g968+g= bun apps/response-portal/build/index.js",
      url: "http://127.0.0.1:29103/respond/unavailable",
      reuseExistingServer: false,
      timeout: 30_000,
    },
  ],
});
