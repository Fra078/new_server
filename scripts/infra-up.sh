#!/bin/bash
# Avvia/aggiorna il livello infrastruttura (core + portainer), gestito fuori da Portainer.
# Va eseguito prima degli stack applicativi. Uso: scripts/infra-up.sh
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)

docker volume inspect portainer_data >/dev/null 2>&1 || docker volume create portainer_data >/dev/null
# Rete dei servizi media (*arr, download client, Jellyfin, Navidrome, Homepage, Kuma).
# Creata qui perché compose crea solo le reti usate da un suo servizio.
docker network inspect media_net >/dev/null 2>&1 || docker network create media_net >/dev/null
for s in core portainer; do
    echo "== $s"
    docker compose --env-file "$REPO/.env" -f "$REPO/$s/docker-compose.yaml" up -d --remove-orphans
done
