#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[wrangler-prep] $*"
}

PINNED_WRANGLER_VERSION="1.19.8"
KV_TITLE_FRAGMENT="KV_STATUS_PAGE"
WRANGLER_TOML="wrangler.toml"

log "Ensuring Wrangler v${PINNED_WRANGLER_VERSION} is installed"
npm uninstall -g @cloudflare/wrangler >/dev/null 2>&1 || true
npm install -g @cloudflare/wrangler@"${PINNED_WRANGLER_VERSION}"

log "Ensuring KV namespace '${KV_TITLE_FRAGMENT}' exists"
if ! wrangler kv:namespace list 2>/dev/null | grep -q "${KV_TITLE_FRAGMENT}"; then
  wrangler kv:namespace create "${KV_TITLE_FRAGMENT}"
else
  log "KV namespace already present, skipping creation"
fi

log "Resolving KV namespace id"
KV_NAMESPACE_ID="$(wrangler kv:namespace list 2>/dev/null \
  | node -e "const fs=require('fs'); const s=fs.readFileSync(0,'utf8'); const m=(s.match(/\\[[\\s\\S]*\\]/)||[]).pop(); const a=m?JSON.parse(m):[]; const kv=a.find(k=>k.title&&k.title.includes('${KV_TITLE_FRAGMENT}')); if(!kv){process.exit(1);} process.stdout.write(kv.id);")"

if [[ -z "${KV_NAMESPACE_ID}" ]]; then
  echo "Failed to resolve KV namespace id for ${KV_TITLE_FRAGMENT}" >&2
  exit 1
fi

# expose KV namespace id to later workflow commands (postCommands)
export KV_NAMESPACE_ID
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "KV_NAMESPACE_ID=${KV_NAMESPACE_ID}" >> "${GITHUB_ENV}"
fi

log "Injecting env.production block into ${WRANGLER_TOML}"
if grep -q '^\[env\.production\]' "${WRANGLER_TOML}"; then
  log "Existing env.production block found, removing to avoid duplicates"
  perl -0pi -e 's/\n\[env\.production\][\s\S]*$//' "${WRANGLER_TOML}"
fi
# Wrangler v1 expects a hyphen here (kv-namespaces). Wrangler v2+ uses
# kv_namespaces (underscore), but this project pins v1 in CI. Use the v1 key.
printf '\n[env.production]\nkv-namespaces = [{ binding = "KV_STATUS_PAGE", id = "%s" }]\n' "${KV_NAMESPACE_ID}" >> "${WRANGLER_TOML}"

log "Ensuring notification secrets have defaults"
if [ -z "${SECRET_SLACK_WEBHOOK_URL:-}" ]; then
  log "SECRET_SLACK_WEBHOOK_URL missing, using placeholder"
  SECRET_SLACK_WEBHOOK_URL="default-gh-action-secret"
fi
if [ -z "${SECRET_TELEGRAM_API_TOKEN:-}" ]; then
  log "SECRET_TELEGRAM_API_TOKEN missing, using placeholder"
  SECRET_TELEGRAM_API_TOKEN="default-gh-action-secret"
fi
if [ -z "${SECRET_TELEGRAM_CHAT_ID:-}" ]; then
  log "SECRET_TELEGRAM_CHAT_ID missing, using placeholder"
  SECRET_TELEGRAM_CHAT_ID="default-gh-action-secret"
fi
if [ -z "${SECRET_DISCORD_WEBHOOK_URL:-}" ]; then
  log "SECRET_DISCORD_WEBHOOK_URL missing, using placeholder"
  SECRET_DISCORD_WEBHOOK_URL="default-gh-action-secret"
fi
