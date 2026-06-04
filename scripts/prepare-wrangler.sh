#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[wrangler-prep] $*"
}

KV_TITLE_FRAGMENT="KV_STATUS_PAGE"
WRANGLER_TOML="wrangler.toml"
CF_API_BASE="https://api.cloudflare.com/client/v4"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

cf_api() {
  curl -fsS \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "$@"
}

require_env "CF_ACCOUNT_ID"
require_env "CF_API_TOKEN"

log "Resolving KV namespace '${KV_TITLE_FRAGMENT}'"
KV_LIST_JSON="$(cf_api "${CF_API_BASE}/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces?per_page=100")"

KV_NAMESPACE_ID="$(printf '%s' "${KV_LIST_JSON}" \
  | node -e "const fs=require('fs'); const s=fs.readFileSync(0,'utf8'); const data=JSON.parse(s); const items=Array.isArray(data.result)?data.result:[]; const kv=items.find((item)=>item.title&&item.title.includes('${KV_TITLE_FRAGMENT}')); if(kv&&kv.id){process.stdout.write(kv.id);}")"

if [[ -z "${KV_NAMESPACE_ID}" ]]; then
  log "KV namespace not found, creating it"
  KV_CREATE_JSON="$(cf_api -X POST "${CF_API_BASE}/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces" --data "{\"title\":\"${KV_TITLE_FRAGMENT}\"}")"
  KV_NAMESPACE_ID="$(printf '%s' "${KV_CREATE_JSON}" \
    | node -e "const fs=require('fs'); const s=fs.readFileSync(0,'utf8'); const data=JSON.parse(s); const id=data&&data.result&&data.result.id; if(id){process.stdout.write(id);} else {process.exit(1);}")"
fi

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
printf '\n[env.production]\nkv_namespaces = [{ binding = "KV_STATUS_PAGE", id = "%s" }]\n' "${KV_NAMESPACE_ID}" >> "${WRANGLER_TOML}"
