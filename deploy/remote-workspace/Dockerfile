FROM docker.io/library/node:22-bookworm-slim@sha256:be979e5523c76fa4d5ca4ebd3099078f220aa47ec39c48ad5b5df9314debd6eb AS base
WORKDIR /opt/workspace-tools

FROM base AS dependencies
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund

FROM base AS agent
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git ripgrep bubblewrap \
    && rm -rf /var/lib/apt/lists/* \
    && install -d -m 0700 -o node -g node /workspace /workspace/browser-output /home/node/.codex /home/node/run
COPY --from=dependencies /opt/workspace-tools/node_modules/@openai ./node_modules/@openai
RUN ln -s /opt/workspace-tools/node_modules/@openai/codex/bin/codex.js /usr/local/bin/codex \
    && codex --version
USER node
ENV HOME=/home/node CODEX_HOME=/home/node/.codex
WORKDIR /workspace
CMD ["codex", "-c", "mcp_servers.browser.url=\"http://browser:8931/mcp\"", "app-server", "--listen", "unix:///home/node/run/codex.sock"]

FROM base AS browser
ARG CHROME_VERSION=158.0.8127.88
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl unzip fonts-liberation libasound2 libatk-bridge2.0-0 libatk1.0-0 \
    libcups2 libdbus-1-3 libdrm2 libgbm1 libgtk-3-0 libnspr4 libnss3 libxcomposite1 \
    libxdamage1 libxfixes3 libxkbcommon0 libxrandr2 xdg-utils \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL --retry 3 "https://storage.googleapis.com/chrome-for-testing-public/${CHROME_VERSION}/linux64/chrome-linux64.zip" -o /tmp/chrome.zip \
    && echo "59e3b43f8b3aaa292238fbdcfb36a93127debd53e212510dcdc2cc8812b4b57e  /tmp/chrome.zip" | sha256sum -c - \
    && unzip -q /tmp/chrome.zip -d /opt && rm /tmp/chrome.zip \
    && install -d -m 0700 -o node -g node /home/node/profile /workspace /workspace/browser-output
COPY --from=dependencies /opt/workspace-tools/node_modules/@playwright ./node_modules/@playwright
COPY --from=dependencies /opt/workspace-tools/node_modules/playwright ./node_modules/playwright
COPY --from=dependencies /opt/workspace-tools/node_modules/playwright-core ./node_modules/playwright-core
USER node
ENV HOME=/home/node
WORKDIR /workspace
CMD ["node", "/opt/workspace-tools/node_modules/@playwright/mcp/cli.js", "--output-dir", "/workspace/browser-output", "--headless", "--sandbox", "--executable-path", "/opt/chrome-linux64/chrome", "--user-data-dir", "/home/node/profile", "--shared-browser-context", "--host", "0.0.0.0", "--allowed-hosts", "browser:8931", "--port", "8931"]
