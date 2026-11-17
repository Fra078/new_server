#!/bin/bash
# Crea o ridistribuisce in Portainer gli stack applicativi (git stack da questo repo),
# passando a ciascuno le variabili prese da .env.
# Uso: scripts/portainer-stacks.sh [stack ...]    (senza argomenti: tutti, nell'ordine sotto)
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
set -a
# shellcheck source=/dev/null
. "$REPO/.env"
set +a

STACKS=(homeassistant monitoring arr downloads music media office homepage)
STACK_VARS=(TZ PUID PGID APPDATA MEDIA_PATH OFFICE_PATH HOMEPAGE_ALLOWED_HOSTS LIDARR_API_KEY)

api() {
    local method=$1 path=$2
    shift 2
    curl -fsS -X "$method" -H "X-API-Key: $PORTAINER_TOKEN" -H 'Content-Type: application/json' \
        "$PORTAINER_URL/api$path" "$@"
}

ep=${PORTAINER_ENDPOINT_ID:-}
[ -n "$ep" ] || ep=$(api GET /endpoints | jq -r '[.[] | select(.Type == 1)][0].Id')

env_json=$(for v in "${STACK_VARS[@]}"; do
    jq -n --arg n "$v" --arg v "${!v}" '{name: $n, value: $v}'
done | jq -s .)

existing=$(api GET /stacks)
targets=("$@")
((${#targets[@]})) || targets=("${STACKS[@]}")

for name in "${targets[@]}"; do
    id=$(jq -r --arg n "$name" '[.[] | select(.Name == $n)][0].Id // empty' <<<"$existing")
    if [ -n "$id" ]; then
        echo "== redeploy $name (stack $id)"
        api PUT "/stacks/$id/git/redeploy?endpointId=$ep" -d "$(jq -n \
            --argjson env "$env_json" --arg ref "$REPO_REF" \
            '{env: $env, prune: true, pullImage: true, repositoryReferenceName: $ref}')" >/dev/null
    else
        echo "== create $name"
        api POST "/stacks/create/standalone/repository?endpointId=$ep" -d "$(jq -n \
            --argjson env "$env_json" --arg n "$name" --arg url "$REPO_URL" --arg ref "$REPO_REF" \
            '{name: $n, repositoryURL: $url, repositoryReferenceName: $ref,
              composeFile: ($n + "/docker-compose.yaml"), env: $env,
              autoUpdate: {interval: "5m"}}')" >/dev/null
    fi
done
