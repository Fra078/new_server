#!/bin/bash
# Al boot: attende il NAS (il My Cloud Home impiega minuti a ripartire dopo un blackout),
# monta /mnt/mycloud e avvia i container che ne dipendono.
# Se dopo 40 minuti il NAS non c'è, esce: il watchdog continuerà a riprovare ogni minuto.
set -u
# shellcheck source=/dev/null
. /usr/local/lib/homeserver/nas-lib.sh
take_lock wait

deadline=$((SECONDS + 2400))
until nas_reachable; do
    if ((SECONDS > deadline)); then
        log "NAS $NAS_HOST non raggiungibile dopo 40 minuti, passo al watchdog"
        set_state down
        exit 0
    fi
    sleep 10
done
log "NAS raggiungibile dopo ${SECONDS}s"

# Il NAS può accettare connessioni prima che le share siano pronte: riprova il mount.
until nas_mount; do
    nas_umount
    if ((SECONDS > deadline)); then
        log "Mount di $NAS_MOUNT fallito, passo al watchdog"
        set_state down
        exit 0
    fi
    sleep 15
done

log "NAS montato e verificato"
set_state up
echo 0 >"$STATE_DIR/nas.fails"
start_nas_containers
kuma_push "${KUMA_PUSH_NAS:-}" up "NAS montato al boot"
