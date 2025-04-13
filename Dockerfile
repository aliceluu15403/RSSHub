# --- dep-builder ---
FROM node:22-bookworm AS dep-builder
WORKDIR /app
ARG USE_CHINA_NPM_REGISTRY=0
RUN \
    set -ex && \
    npm install -g corepack@latest && \
    corepack enable pnpm && \
    if [ "$USE_CHINA_NPM_REGISTRY" = 1 ]; then \
        echo 'use npm mirror' && \
        npm config set registry https://registry.npmmirror.com && \
        yarn config set registry https://registry.npmmirror.com && \
        pnpm config set registry https://registry.npmmirror.com ; \
    fi;
COPY ./tsconfig.json ./pnpm-lock.yaml ./package.json /app/
RUN \
    set -ex && \
    export PUPPETEER_SKIP_DOWNLOAD=true && \
    pnpm install --frozen-lockfile && \
    pnpm rebuild
RUN npx puppeteer browsers install chrome
RUN set -ex \
    && export PUPPETEER_SKIP_DOWNLOAD=true \
    && pnpm install --frozen-lockfile \
    && pnpm rebuild

# --- dep-version-parser ---
FROM debian:bookworm-slim AS dep-version-parser
WORKDIR /ver
COPY ./package.json /app/
RUN \
    set -ex && \
    grep -Po '(?<="puppeteer": ")[^\s"]*(?=")' /app/package.json | tee /ver/.puppeteer_version

# --- docker-minifier ---
FROM node:22-bookworm-slim AS docker-minifier
WORKDIR /app
COPY . /app
COPY --from=dep-builder /app /app
# Fake a .git directory to avoid fatal error
RUN mkdir -p /app/.git/refs/heads && \
    echo "ref: refs/heads/fake-branch" > /app/.git/HEAD && \
    echo "0123456789abcdef0123456789abcdef01234567" > /app/.git/refs/heads/fake-branch && \
    npm run build && \
    rm -rf /app/.git
RUN set -ex && \
    npm run build && \
    npm config set git false && \
    ls -la /app && \
    du -hd1 /app

# --- chromium-downloader ---
FROM node:22-bookworm-slim AS chromium-downloader
WORKDIR /app
COPY ./.puppeteerrc.cjs /app/
COPY --from=dep-version-parser /ver/.puppeteer_version /app/.puppeteer_version
ARG TARGETPLATFORM
ARG USE_CHINA_NPM_REGISTRY=0
ARG PUPPETEER_SKIP_DOWNLOAD=1
RUN \
    set -ex ; \
    if [ "$PUPPETEER_SKIP_DOWNLOAD" = 0 ] && [ "$TARGETPLATFORM" = 'linux/amd64' ]; then \
        if [ "$USE_CHINA_NPM_REGISTRY" = 1 ]; then \
            npm config set registry https://registry.npmmirror.com && \
            yarn config set registry https://registry.npmmirror.com && \
            pnpm config set registry https://registry.npmmirror.com ; \
        fi; \
        echo 'Downloading Chromium...' && \
        unset PUPPETEER_SKIP_DOWNLOAD && \
        npm install -g corepack@latest && \
        corepack use pnpm@latest-9 && \
        pnpm add puppeteer@$(cat /app/.puppeteer_version) --save-prod && \
        pnpm rb ; \
    else \
        mkdir -p /app/node_modules/.cache/puppeteer ; \
    fi;

# --- app (final image) ---
FROM node:22-bookworm-slim AS app
RUN apt-get update && \
    apt-get install -y wget gnupg ca-certificates && \
    wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | apt-key add - && \
    echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    apt-get install -y google-chrome-stable

LABEL org.opencontainers.image.authors="https://github.com/DIYgod/RSSHub"
ENV NODE_ENV=production
ENV TZ=Asia/Shanghai
WORKDIR /app

ARG TARGETPLATFORM
ARG PUPPETEER_SKIP_DOWNLOAD=1
RUN \
    set -ex && \
    apt-get update && \
    apt-get install -yq --no-install-recommends \
        dumb-init git curl \
    ; \
    if [ "$PUPPETEER_SKIP_DOWNLOAD" = 0 ]; then \
        if [ "$TARGETPLATFORM" = 'linux/amd64' ]; then \
            apt-get install -yq --no-install-recommends \
                ca-certificates fonts-liberation wget xdg-utils \
                libasound2 libatk-bridge2.0-0 libatk1.0-0 libatspi2.0-0 libcairo2 libcups2 libdbus-1-3 libdrm2 \
                libexpat1 libgbm1 libglib2.0-0 libnspr4 libnss3 libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 \
                libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2 \
            ; \
        else \
            apt-get install -yq --no-install-recommends \
                chromium \
            && \
            echo "CHROMIUM_EXECUTABLE_PATH=$(which chromium)" | tee /app/.env ; \
        fi; \
    fi; \
    rm -rf /var/lib/apt/lists/*
COPY --from=chromium-downloader /app/node_modules/.cache/puppeteer /app/node_modules/.cache/puppeteer
RUN \
    set -ex && \
    if [ "$PUPPETEER_SKIP_DOWNLOAD" = 0 ] && [ "$TARGETPLATFORM" = 'linux/amd64' ]; then \
        echo 'Verifying Chromium installation...' && \
        if ldd $(find /app/node_modules/.cache/puppeteer/ -name chrome -type f) | grep "not found"; then \
            echo "!!! Chromium has unmet shared libs !!!" && \
            exit 1 ; \
        else \
            echo "Awesome! All shared libs are met!" ; \
        fi; \
    fi;
COPY --from=docker-minifier /app /app

# ✅ Di chuyển việc xoá `.git` sang đây
RUN set -ex && \
    find /app -type d -name ".git" -exec rm -rf {} + 2>/dev/null || true && \
    [ ! -d ".git" ] || (echo "Git still exists!" && exit 1)

EXPOSE 1200
ENTRYPOINT ["dumb-init", "--"]
CMD ["npm", "run", "start"]
