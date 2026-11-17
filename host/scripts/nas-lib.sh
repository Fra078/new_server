# shellcheck shell=bash
# Funzioni condivise per NAS e backup. Installato in /usr/local/lib/homeserver/.
# I container che dipendono dal NAS hanno la label homeserver.requires-nas=true.

NAS_HOST=192.168.1.18
NAS_PORT=445
NAS_MOUNT=/mnt/mycloud
NAS_SENTINEL=$NAS_MOUNT/media_stack/.nas-sentinel
NAS_LABEL=homeserver.requires-nas=true
STATE_DIR=/run/homeserver

# KUMA_PUSH_NAS / KUMA_PUSH_BACKUP (URL push di Uptime Kuma, senza query string)
# shellcheck source=/dev/null
[ -r /etc/homeserver/homeserver.env ] && . /etc/homeserver/homeserver.env

mkdir -p "$STATE_DIR"

log() { echo "$*"; } # stdout -> journald

# Un solo script NAS/backup alla volta. $1 = "wait" per attendere, altrimenti esce se occupato.
take_lock() {
    exec 9>"$STATE_DIR/nas.lock"
    if [ "${1:-}" = wait ]; then flock 9; else flock -n 9 || exit 0; fi
}

nas_reachable() {
    timeout 3 bash -c "</dev/tcp/$NAS_HOST/$NAS_PORT" 2>/dev/null
}

# Montato E risponde E è la share giusta (sentinella). Timeout: un CIFS morto può bloccare stat.
nas_healthy() {
    timeout 10 mountpoint -q "$NAS_MOUNT" && timeout 10 stat "$NAS_SENTINEL" >/dev/null 2>&1
}

nas_mount() {
    timeout 10 mountpoint -q "$NAS_MOUNT" || timeout 45 mount "$NAS_MOUNT" || return 1
    nas_healthy
}

nas_umount() {
    timeout 30 umount -l "$NAS_MOUNT" 2>/dev/null || true
}

start_nas_containers() {
    local ids
    mapfile -t ids < <(docker ps -aq --filter "label=$NAS_LABEL" --filter status=exited --filter status=created)
    ((${#ids[@]})) || return 0
    log "Avvio container NAS: $(docker inspect -f '{{.Name}}' "${ids[@]}" | tr -d / | tr '\n' ' ')"
    docker start "${ids[@]}" >/dev/null
}

stop_nas_containers() {
    local ids
    mapfile -t ids < <(docker ps -q --filter "label=$NAS_LABEL")
    ((${#ids[@]})) || return 0
    log "Fermo container NAS: $(docker inspect -f '{{.Name}}' "${ids[@]}" | tr -d / | tr '\n' ' ')"
    timeout 180 docker stop -t 60 "${ids[@]}" >/dev/null || log "ATTENZIONE: docker stop non completato"
}

# kuma_push <url> <up|down> <messaggio>
kuma_push() {
    [ -n "${1:-}" ] || return 0
    curl -fsS -m 10 -G "${1%%\?*}" --data-urlencode "status=$2" --data-urlencode "msg=$3" >/dev/null 2>&1 || true
}

set_state() { echo "$1" >"$STATE_DIR/nas.state"; }
get_state() { cat "$STATE_DIR/nas.state" 2>/dev/null || echo unknown; }
