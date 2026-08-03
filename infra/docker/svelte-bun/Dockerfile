# syntax=docker/dockerfile:1.12
FROM oven/bun:1.3.14-debian@sha256:9dba1a1b43ce28c9d7931bfc4eb00feb63b0114720a0277a8f939ae4dfc9db6f AS build
WORKDIR /workspace
COPY package.json bun.lock tsconfig.json biome.jsonc ./
COPY apps apps
COPY packages packages
COPY specs specs
RUN bun install --frozen-lockfile

FROM build AS public-web-build
RUN bun --filter @gurine/public-web build

FROM build AS review-console-build
RUN bun --filter @gurine/review-console build

FROM build AS response-portal-build
RUN bun --filter @gurine/response-portal build

FROM build AS runtime-deps
RUN bun install --frozen-lockfile --production \
    && mkdir /runtime-node-modules \
    && cp -aL /workspace/node_modules/.bun/node_modules/. /runtime-node-modules/

FROM oven/bun:1.3.14-debian@sha256:9dba1a1b43ce28c9d7931bfc4eb00feb63b0114720a0277a8f939ae4dfc9db6f AS runtime
RUN groupadd --system --gid 10001 gurine \
    && useradd --system --uid 10001 --gid gurine --home-dir /nonexistent --shell /usr/sbin/nologin gurine
ENV HOME=/tmp \
    BUN_RUNTIME_TRANSPILER_CACHE_PATH=/tmp/bun-runtime-cache
USER 10001:10001
WORKDIR /app
COPY --from=runtime-deps /runtime-node-modules ./node_modules

FROM runtime AS public-web
COPY --from=public-web-build /workspace/apps/public-web/build ./build
ENTRYPOINT ["bun", "--no-install", "./build/index.js"]

FROM runtime AS review-console
COPY --from=review-console-build /workspace/apps/review-console/build ./build
ENTRYPOINT ["bun", "--no-install", "./build/index.js"]

FROM runtime AS response-portal
COPY --from=response-portal-build /workspace/apps/response-portal/build ./build
ENTRYPOINT ["bun", "--no-install", "./build/index.js"]
