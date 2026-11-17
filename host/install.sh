#!/bin/bash
# Applica al sistema la configurazione host di questo repo. Idempotente: si può rilanciare.
# Uso: sudo /opt/homeserver/host/install.sh
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
H=$REPO/host
[ "$(id -u)" = 0 ] || { echo "Eseguire con sudo"; exit 1; }
NOTES=()

echo "== Pacchetti"
apt-get install -y -q restic unattended-upgrades smartmontools jq curl >/dev/null

echo "== /etc/homeserver"
install -d -m 700 /etc/homeserver
[ -f /etc/homeserver/homeserver.env ] || install -m 600 "$H/homeserver.env.example" /etc/homeserver/homeserver.env
if [ ! -f /etc/homeserver/restic.pass ]; then
    (umask 077 && head -c 32 /dev/urandom | base64 >/etc/homeserver/restic.pass)
    NOTES+=("Creata una nuova password restic in /etc/homeserver/restic.pass: COPIALA nel password manager")
fi
[ -f "$REPO/.env" ] && chmod 600 "$REPO/.env"

echo "== Script e unit systemd"
install -d /usr/local/lib/homeserver
install -m 755 "$H"/scripts/*.sh /usr/local/lib/homeserver/
install -m 644 "$H/backup/excludes.txt" /usr/local/lib/homeserver/backup-excludes.txt
install -m 644 "$H"/systemd/* /etc/systemd/system/
systemctl daemon-reload
systemctl enable -q nas-mount.service nas-watchdog.timer backup.timer backup-check.timer
systemctl start nas-watchdog.timer backup.timer backup-check.timer

echo "== fstab NAS"
line=$(grep -v '^#' "$H/fstab.cifs")
if ! grep -qxF "$line" /etc/fstab; then
    # Un vecchio automount va smontato prima di cambiare fstab, altrimenti resta orfano e ogni
    # accesso a /mnt/mycloud si blocca. Richiede che i container che usano il NAS siano fermi.
    if systemctl is-active -q mnt-mycloud.automount; then
        echo "ATTENZIONE: automount attivo. Fermare i container che usano il NAS e poi:"
        echo "  systemctl stop mnt-mycloud.automount mnt-mycloud.mount && $0"
        exit 1
    fi
    cp /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d%H%M%S)"
    sed -i '\#[[:space:]]/mnt/mycloud[[:space:]]#d' /etc/fstab
    echo "$line" >>/etc/fstab
    systemctl daemon-reload
fi
install -d /mnt/mycloud
if mountpoint -q /mnt/mycloud; then
    # Da montato lsattr vede il NAS, non la cartella sottostante: la si controlla con un bind di /
    [ -e /mnt/mycloud/media_stack/.nas-sentinel ] || touch /mnt/mycloud/media_stack/.nas-sentinel
    install -d /run/rootview && mount --bind / /run/rootview
    lsattr -d /run/rootview/mnt/mycloud | grep -q -- '-i-' || {
        [ -z "$(ls -A /run/rootview/mnt/mycloud)" ] || NOTES+=("Ci sono file SOTTO il mountpoint /mnt/mycloud (sull'NVMe): controllarli")
        chattr +i /run/rootview/mnt/mycloud
    }
    umount /run/rootview
else
    chattr +i /mnt/mycloud
fi

echo "== Docker daemon.json"
if ! cmp -s "$H/docker/daemon.json" /etc/docker/daemon.json; then
    install -m 644 "$H/docker/daemon.json" /etc/docker/daemon.json
    NOTES+=("daemon.json cambiato: 'systemctl restart docker' e poi ricreare i container (redeploy) per applicare la rotazione log")
fi

echo "== SSH"
install -m 644 "$H/sshd/10-hardening.conf" /etc/ssh/sshd_config.d/10-hardening.conf
sshd -t && systemctl reload ssh

echo "== unattended-upgrades"
install -m 644 "$H/apt/20auto-upgrades" "$H/apt/52unattended-homeserver" /etc/apt/apt.conf.d/

echo "== cgroup memoria (limiti RAM dei container)"
CMDLINE=/boot/firmware/cmdline.txt
if ! grep -q 'cgroup_enable=memory' "$CMDLINE"; then
    cp "$CMDLINE" "$CMDLINE.bak"
    sed -i '1 s/$/ cgroup_enable=memory cgroup_memory=1/' "$CMDLINE"
    NOTES+=("cmdline.txt modificato: serve un riavvio")
fi

echo "== Tailscale Serve"
"$H/scripts/tailscale-serve.sh" "$H/tailscale/serve.json" ||
    NOTES+=("Tailscale Serve non applicato del tutto: i Services nuovi vanno prima definiti nella admin console")

echo
echo "Fatto."
for n in "${NOTES[@]}"; do echo " * $n"; done
