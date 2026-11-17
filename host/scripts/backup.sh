#!/bin/bash
# Backup notturno (backup.timer) con restic sul NAS.
#   backup.sh         -> backup + retention
#   backup.sh check   -> verifica integrità (backup-check.timer, settimanale)
set -uo pipefail
# shellcheck source=/dev/null
. /usr/local/lib/homeserver/nas-lib.sh

export RESTIC_REPOSITORY=$NAS_MOUNT/backup/restic-raspberrypi
export RESTIC_PASSWORD_FILE=/etc/homeserver/restic.pass
export RESTIC_CACHE_DIR=/var/cache/restic
EXCLUDES=/usr/local/lib/homeserver/backup-excludes.txt
STAGE=/var/backups/homeserver

# Container con database SQLite: fermati per avere copie coerenti (~1-2 minuti).
# Home Assistant e Mosquitto restano accesi (il db storico di HA è escluso).
STOP_FOR_BACKUP=(sonarr radarr lidarr prowlarr jellyfin navidrome uptime_kuma portainer)

PATHS=(
    /home/fra078/appdata
    /var/lib/docker/volumes/portainer_data
    /opt/homeserver/.env
    /etc/fstab
    /etc/.smbcreds
    /etc/homeserver
    /etc/docker/daemon.json
    /etc/ssh/sshd_config.d
    /home/fra078/.ssh/authorized_keys
    "$STAGE"
)

fail() {
    log "BACKUP FALLITO: $*"
    kuma_push "${KUMA_PUSH_BACKUP:-}" down "$*"
    exit 1
}

take_lock wait
nas_healthy || fail "NAS non montato"

if [ "${1:-}" = check ]; then
    restic check --read-data-subset=5% || fail "restic check"
    log "restic check OK"
    exit 0
fi

# Metadati non presenti su disco come file
mkdir -p "$STAGE"
tailscale serve get-config --all >"$STAGE/tailscale-serve.json" 2>/dev/null || true
dpkg --get-selections >"$STAGE/dpkg-selections.txt"
mapfile -t all_ids < <(docker ps -aq)
docker inspect "${all_ids[@]}" >"$STAGE/docker-inspect.json" 2>/dev/null || true
cp /boot/firmware/cmdline.txt /boot/firmware/config.txt "$STAGE/" 2>/dev/null || true

running=()
for c in "${STOP_FOR_BACKUP[@]}"; do
    [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] && running+=("$c")
done
restart_containers() { ((${#running[@]})) && docker start "${running[@]}" >/dev/null; }
trap restart_containers EXIT

((${#running[@]})) && docker stop -t 60 "${running[@]}" >/dev/null
restic backup --tag nightly --exclude-caches --exclude-file="$EXCLUDES" "${PATHS[@]}"
rc=$?
restart_containers
trap - EXIT
# rc 3 = alcuni file non leggibili, snapshot comunque creato
((rc == 0 || rc == 3)) || fail "restic backup rc=$rc"

restic forget --tag nightly --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune || fail "restic forget"

# Kuma è appena ripartito: un attimo prima di notificarlo
sleep 30
kuma_push "${KUMA_PUSH_BACKUP:-}" up "OK rc=$rc"
log "Backup completato (rc=$rc)"
