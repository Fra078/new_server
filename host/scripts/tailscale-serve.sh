#!/bin/bash
# Porta i Tailscale Services di questo nodo allo stato descritto in serve.json
# (stesso formato di `tailscale serve get-config --all`).
# Non usa `set-config` perché interpreta "tcp:443": "http://..." come HTTP semplice,
# in conflitto con i Services HTTPS: applica gli endpoint con i comandi imperativi.
# I Services nuovi vanno prima definiti nella admin console di Tailscale.
# Uso: tailscale-serve.sh <serve.json>
set -euo pipefail
desired=$(cat "$1")
current=$(tailscale serve get-config --all)
rc=0

# Rimuove i Services non più previsti
for svc in $(jq -r '.services // {} | keys[]' <<<"$current"); do
    if [ "$(jq --arg s "$svc" '.services | has($s)' <<<"$desired")" = false ]; then
        echo "rimuovo $svc"
        tailscale serve clear "$svc"
    fi
done

# Applica quelli nuovi o cambiati
for svc in $(jq -r '.services | keys[]' <<<"$desired"); do
    want=$(jq -c --arg s "$svc" '.services[$s]' <<<"$desired")
    have=$(jq -c --arg s "$svc" '.services[$s] // null' <<<"$current")
    [ "$want" = "$have" ] && continue
    echo "configuro $svc"
    [ "$have" != null ] && tailscale serve clear "$svc"
    while IFS=$'\t' read -r ep target; do
        port=${ep#tcp:}
        case $target in
            http://* | https://*) args=(--https="$port") ;;
            tcp://*) args=(--tcp="$port") ;;
            *) echo "endpoint non supportato: $ep -> $target"; rc=1; continue ;;
        esac
        tailscale serve --service="$svc" "${args[@]}" "$target" >/dev/null || {
            echo "ERRORE su $svc (definito nella admin console?)"
            rc=1
        }
    done < <(jq -r --arg s "$svc" '.services[$s].endpoints | to_entries[] | [.key, .value] | @tsv' <<<"$desired")
done
exit $rc
