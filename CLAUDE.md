# Home server — documento di progetto

Documento di riferimento per chi (umano o Claude) deve capire, modificare o ricostruire il server.
Tenerlo aggiornato a ogni cambiamento strutturale.

## In breve
- **Hardware:** Raspberry Pi 5, 4 GB RAM, NVMe 128 GB (sistema + config dei container). Hostname `raspberrypi`, LAN `192.168.1.54`, Tailscale `100.82.132.126`.
- **OS:** Debian 13 (trixie), kernel Raspberry Pi. Utente `fra078` (uid/gid 1000, gruppo `docker` = 985).
- **NAS:** WD My Cloud Home `192.168.1.18`, share SMB `admin123` montata su `/mnt/mycloud` (CIFS). Contiene media, download e documenti. Gli hardlink funzionano (download e media sullo stesso fs).
- **Accesso:** solo **Tailscale** (tailnet `cetacean-fish.ts.net`). Ogni servizio ha un Tailscale Service `https://<nome>.cetacean-fish.ts.net` che inoltra a `127.0.0.1:<porta>`. In LAN restano aperti solo Jellyfin (8096), Mosquitto (1883) e Home Assistant (8123, host network).
- **Gestione container:** Portainer (git stack da questo repo, branch `main`). **Ogni stack controlla `main` ogni 5 minuti e si ridistribuisce da solo**: un merge su `main` (anche di una PR di Renovate) va in produzione entro 5 minuti. Le variabili degli stack vivono in Portainer: dopo una modifica a `.env` lanciare `scripts/portainer-stacks.sh`.
- **Repo sul Pi:** `/opt/homeserver` (clone), variabili in `/opt/homeserver/.env` (non in git).

## Architettura
```
Internet ── router ── LAN 192.168.1.0/24
                       ├─ NAS 192.168.1.18 (SMB) ── /mnt/mycloud ── media_stack/{downloads,media}, office/, ...
                       └─ Pi 5 192.168.1.54
                            ├─ Tailscale: SSH + Services HTTPS -> 127.0.0.1:<porta>   (host/tailscale/serve.json)
                            ├─ systemd: nas-mount, nas-watchdog, backup               (host/systemd)
                            └─ Docker
                                 ├─ infra (docker compose, fuori da Portainer): core/, portainer/
                                 └─ app (Portainer git stack): homeassistant monitoring arr downloads music media office homepage
```

### Reti Docker
| Rete | Chi | Perché |
|---|---|---|
| `media_net` (da `scripts/infra-up.sh`) | prowlarr, sonarr, radarr, lidarr, qbittorrent, slskd, deemix, lidarr-downloader, jellyfin, navidrome, homepage, uptime_kuma | devono parlarsi: *arr ↔ download client ↔ plugin Lidarr ↔ Jellyfin; widget e monitor |
| `socket_net` (da `core/`, `internal`) | socket-proxy, homepage, uptime_kuma | accesso al Docker API in **sola lettura**, nessuna uscita a Internet |
| `mgmt_net` (da `portainer/`) | portainer, homepage | widget Portainer; Portainer isolato da tutto il resto |
| `office_default` | filebrowser, webdav | isolati |
| `homeassistant_default` | mosquitto | HA è in host network e lo raggiunge su `localhost:1883` |
| host | homeassistant, glances | discovery/Bluetooth (HA), metriche host (Glances) |

Solo **Portainer** monta `docker.sock` in scrittura. Homepage e Kuma usano `tcp://socket-proxy:2375`; Glances `tcp://127.0.0.1:2375`.

### Servizi
| Stack | Container | Porta host | URL Tailscale | Usa NAS |
|---|---|---|---|---|
| core | socket-proxy | 127.0.0.1:2375 | — | no |
| portainer | portainer | 127.0.0.1:9000 | portainer | no |
| homeassistant | homeassistant | 8123 (host) | homeassistant | no |
| homeassistant | mosquitto | **1883 LAN** | — | no |
| monitoring | uptime_kuma | 127.0.0.1:3001 | kuma | no |
| monitoring | glances | 127.0.0.1:61208 (host) | glances | no |
| arr | prowlarr | 127.0.0.1:9696 | prowlarr | no |
| arr | sonarr / radarr / lidarr | 127.0.0.1:8989 / 7878 / 8686 | sonarr / radarr / lidarr | sì |
| downloads | qbittorrent | 127.0.0.1:9617 | qbit | sì |
| music | deemix / slskd / lidarr-downloader | 127.0.0.1:6595 / 5030 / 5005 | — / slskd / — | sì |
| media | jellyfin | **8096 LAN** | jellyfin | sì |
| media | navidrome | 127.0.0.1:4533 | navidrome | sì |
| office | filebrowser / webdav | 127.0.0.1:8345 / 8660 | files / webdav | sì |
| homepage | homepage | 127.0.0.1:3000 | home | no (vede `/mnt` in sola lettura) |

Il Service `mycloud` (tcp 445 → NAS) permette di raggiungere la share SMB da fuori casa via Tailscale.

### Dati
- **Config container:** `/home/fra078/appdata/<gruppo>/<servizio>` (`APPDATA`). È ciò che va protetto: incluso nel backup.
- **Portainer:** volume `portainer_data` (utenti, impostazioni, variabili degli stack).
- **Media:** `/mnt/mycloud/media_stack` (`MEDIA_PATH`): `downloads/` e `media/{movies,tv,anime,music,Privati}`.
- **Documenti:** `/mnt/mycloud/office` (`OFFICE_PATH`).

## Il NAS e i blackout (perché esistono nas-mount/nas-watchdog)
Problema: dopo un blackout il Pi riparte in ~30 s, il NAS in minuti. Prima i container partivano su una cartella vuota o restavano bloccati su un mount CIFS morto.

Soluzione:
1. `/etc/fstab` monta la share con `noauto` (`host/fstab.cifs`): il boot non la attende.
2. `/mnt/mycloud` (cartella sottostante) è **immutabile** (`chattr +i`): se il NAS non è montato nessuno può scriverci, quindi niente file finiti per sbaglio sull'NVMe.
3. Nei compose i bind verso il NAS hanno `bind.create_host_path: false` e i container hanno la label `homeserver.requires-nas=true`: senza NAS **non partono** (Docker al boot fallisce e li lascia fermi).
4. `nas-mount.service` (al boot): attende la porta 445 del NAS fino a 40 min, monta, verifica la sentinella `/mnt/mycloud/media_stack/.nas-sentinel`, avvia i container con la label.
5. `nas-watchdog.timer` (ogni minuto): se il NAS sparisce (2 controlli falliti) **ferma** i container con la label (così Jellyfin/*arr non vedono la libreria vuota) e smonta; quando torna, rimonta e li riavvia. Notifica Uptime Kuma (monitor push "NAS").
- Stato: `/run/homeserver/nas.state` (`up`/`down`), log: `journalctl -u nas-mount -u nas-watchdog`.
- Un container fermato a mano ma con la label viene riavviato dal watchdog alla prossima ripresa del NAS: per disattivarlo davvero, toglierlo dal compose.
- Consiglio hardware: un piccolo **UPS** per Pi + NAS + router (l'NVMe ha registrato decine di spegnimenti non puliti).

## Backup
- **restic** sul NAS: repo `/mnt/mycloud/backup/restic-raspberrypi`, password `/etc/homeserver/restic.pass` (**copiata anche nel password manager**: senza, i backup sono illeggibili).
- `backup.timer` ogni notte alle 03:30: ferma ~1-2 min i container con SQLite (sonarr, radarr, lidarr, prowlarr, jellyfin, navidrome, uptime_kuma, portainer), copia, li riavvia. Retention 7 giornalieri / 4 settimanali / 6 mensili. `backup-check.timer` la domenica verifica il 5% dei dati.
- **Incluso:** `appdata`, `portainer_data`, `/opt/homeserver/.env`, `/etc/{fstab,.smbcreds,homeserver,docker/daemon.json,ssh/sshd_config.d}`, `authorized_keys`, e in `/var/backups/homeserver` export di Tailscale Serve, pacchetti, `docker inspect`, `cmdline.txt`/`config.txt`.
- **Escluso:** cache/log di Jellyfin, `MediaCover` e log degli *arr, db storico e backup di Home Assistant (`host/backup/excludes.txt`).
- Il NAS stesso **non** ha un backup: `Privati`, `office`, `projects`, `Google Photos` esistono in una sola copia. TODO: copia offsite (es. `restic copy` verso Backblaze B2).

Comandi (come root):
```bash
export RESTIC_REPOSITORY=/mnt/mycloud/backup/restic-raspberrypi RESTIC_PASSWORD_FILE=/etc/homeserver/restic.pass
restic snapshots
restic restore latest --target /tmp/restore --include /home/fra078/appdata/arr/sonarr
systemctl start backup.service && journalctl -u backup -f
```

## Ricostruzione da zero
1. Raspberry Pi OS / Debian trixie su NVMe, utente `fra078`, Docker CE + compose plugin, Tailscale (`tailscale up --ssh`).
2. `/etc/.smbcreds` (600) con `username=` e `password=` della share NAS.
3. `sudo git clone https://github.com/Fra078/new_server /opt/homeserver && sudo chown -R fra078: /opt/homeserver`
4. `sudo /opt/homeserver/host/install.sh` — pacchetti, unit systemd, fstab, SSH, cgroup, Tailscale Serve. Riavviare.
5. Ripristinare la password restic in `/etc/homeserver/restic.pass`, poi:
   `restic restore latest --target /` (riporta `appdata`, `portainer_data`, `.env`, `/etc/homeserver/homeserver.env`, ...).
6. `scripts/infra-up.sh` (core + Portainer), poi `scripts/portainer-stacks.sh` (crea/ridistribuisce gli stack app).
7. Controllare in Tailscale admin console che i Services siano approvati per il nodo.

## Operazioni comuni
- **Aggiornare un servizio:** cambiare il tag dell'immagine nel compose (o accettare la PR di Renovate) → merge su `main` → Portainer lo applica entro 5 minuti (subito: `scripts/portainer-stacks.sh <stack>`).
- **Aggiungere un servizio:** aggiungerlo al compose dello stack giusto con: porta `127.0.0.1:`, `logging`, rete corretta, `bind.create_host_path: false` + label `homeserver.requires-nas` se usa il NAS. Poi un Tailscale Service in `host/tailscale/serve.json` (da definire anche nella admin console) e `sudo host/scripts/tailscale-serve.sh host/tailscale/serve.json` (non usare `tailscale serve set-config`: tratta gli endpoint come HTTP semplice).
- **Variabili:** sono in `/opt/homeserver/.env`; dopo una modifica `scripts/portainer-stacks.sh` le ripassa a tutti gli stack.
- **Modifiche a core/ o portainer/:** `scripts/infra-up.sh`.
- **Modifiche a host/:** `sudo host/install.sh` (idempotente).
- **Stato NAS:** `cat /run/homeserver/nas.state; journalctl -u nas-watchdog --since -1h`.

## Decisioni e motivazioni
- **Lidarr `nightly`:** richiesto dai plugin Tubifarry (slskd/YouTube) e Deemix.
- **Home Assistant `privileged` + host network:** Bluetooth, mDNS/discovery, dispositivi locali.
- **Jellyfin e Mosquitto in LAN:** TV e dispositivi IoT non usano Tailscale.
- **Portainer fuori da Portainer:** è l'infrastruttura che gestisce gli altri stack; se si rompe deve poter ripartire da `docker compose`.
- **Versioni fissate** (niente `:latest`): gli aggiornamenti arrivano come PR di Renovate e si accettano consapevolmente. Lidarr nightly e le immagini senza tag di versione sono fissate per digest.
- **Rete media_net unica per lo stack media:** i servizi devono comunque parlarsi; separarli ulteriormente aggiungerebbe complessità senza ridurre davvero il rischio. L'isolamento è applicato dove conta: Portainer, socket Docker, office.
- **Kuma per le notifiche:** nessun canale esterno per scelta; monitor push "NAS" e "Backup".
- **`tg_forwarder` rimosso** (novembre 2026).

## TODO
- deemix: probabile rimozione (nessun URL Tailscale; raggiungibile solo con `ssh -L 6595:127.0.0.1:6595`). Rimuovendolo, controllare il plugin Deemix di Lidarr.
- VPN per qBittorrent (e slskd): pronto `downloads/gluetun.example.yaml`, serve un provider con WireGuard + port forwarding.
- Copia offsite del backup e backup dei dati unici del NAS.
- Limiti RAM (`mem_limit`) dopo qualche giorno di misure con i cgroup memoria attivi.
- Uptime Kuma 2.x (migrazione del database da pianificare).
- UPS.

## Storia
- 2026-11-14: ristrutturazione — backup restic, gestione NAS al boot, porte su 127.0.0.1, reti separate, socket-proxy, versioni fissate, rotazione log, hardening SSH, rimozione servizi inutilizzati (tg_forwarder, jellyseerr, mixarr, spotiflac, netdata, speedtest-tracker, dashy, homarr, caddy).
