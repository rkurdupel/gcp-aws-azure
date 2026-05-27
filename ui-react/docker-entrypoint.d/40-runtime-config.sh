#!/bin/sh
set -eu

cat > /usr/share/nginx/html/config.js <<EOF
window.__COIN_OPS_CONFIG__ = {
  proxyUrl: "${PROXY_URL:-/api}",
  historyUrl: "${HISTORY_URL:-/history-api}"
};
EOF
