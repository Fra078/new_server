#!/bin/bash
# Ogni minuto (nas-watchdog.timer):
#  - NAS ok                       -> push "up" (e se prima era giù, riavvia i container NAS)
#  - 2 controlli falliti di fila  -> ferma i container NAS, smonta, push "down"
#  - NAS di nuovo raggiungibile   -> rimonta, verifica, riavvia i container NAS
# Fermare i container quando il NAS manca evita che Jellyfin/*arr vedano la libreria
# vuota e la "puliscano", e che restino bloccati su un mount CIFS morto.
set -u
# shellcheck source=/dev/null
. /usr/local/lib/homeserver/nas-lib.sh
take_lock # se nas-mount.sh o backup.sh stanno lavorando, salta questo giro

state=$(get_state)
fails=$(cat "$STATE_DIR/nas.fails" 2>/dev/null || echo 0)

if nas_healthy; then
    echo 0 >"$STATE_DIR/nas.fails"
    if [ "$state" != up ]; then
        log "NAS di nuovo disponibile (stato precedente: $state)"
        set_state up
        start_nas_containers
    fi
    kuma_push "${KUMA_PUSH_NAS:-}" up OK
    exit 0
fi

fails=$((fails + 1))
echo "$fails" >"$STATE_DIR/nas.fails"
if ((fails < 2)); then
    log "Controllo NAS fallito ($fails), ricontrollo al prossimo giro"
    exit 0
fi

if [ "$state" != down ]; then
    log "NAS non disponibile: fermo i container che ne dipendono"
    stop_nas_containers
    nas_umount
    set_state down
fi
kuma_push "${KUMA_PUSH_NAS:-}" down "NAS non disponibile"

if nas_reachable && nas_mount; then
    log "NAS rimontato"
    set_state up
    echo 0 >"$STATE_DIR/nas.fails"
    start_nas_containers
    kuma_push "${KUMA_PUSH_NAS:-}" up "NAS rimontato"
fi
