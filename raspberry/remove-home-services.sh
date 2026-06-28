#!/bin/bash

set -euo pipefail

BASE_DIR="${HOME}/home-services"
MEDIA_MOUNT_DIR="/mnt/Expansion"
MEDIA_DISK_UUID="010A-F2E7"

require_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "[!] Brakuje polecenia: $command_name"
        exit 1
    fi
}

require_command docker
require_command sudo

echo "[!] To usunie caly katalog:"
echo "    ${BASE_DIR}"
echo
echo "W srodku sa konfiguracje i dane kontenerow, m.in. Pi-hole, Jellyfin i Tailscale."
echo "Dysk ${MEDIA_MOUNT_DIR} nie zostanie skasowany, ale wpis montowania moze zostac usuniety z /etc/fstab."
echo
read -r -p "Wpisz USUN, zeby kontynuowac: " confirmation

if [[ "$confirmation" != "USUN" ]]; then
    echo "Anulowano."
    exit 0
fi

if [[ -f "${BASE_DIR}/docker-compose.yml" ]]; then
    echo "[i] Zatrzymuje kontenery..."
    cd "$BASE_DIR"
    sudo docker compose down --remove-orphans --volumes
else
    echo "[i] Nie znaleziono docker-compose.yml, pomijam zatrzymywanie compose."
fi

if mountpoint -q "$MEDIA_MOUNT_DIR"; then
    echo "[i] Odmontowuje ${MEDIA_MOUNT_DIR}..."
    sudo umount "$MEDIA_MOUNT_DIR" || echo "[!] Nie udalo sie odmontowac ${MEDIA_MOUNT_DIR}; katalog nie bedzie kasowany."
fi

if grep -Eq "^[^#]*UUID=${MEDIA_DISK_UUID}[[:space:]]+${MEDIA_MOUNT_DIR}[[:space:]]" /etc/fstab; then
    echo "[i] Usuwam wpis dysku z /etc/fstab..."
    sudo cp /etc/fstab /etc/fstab.home-services.bak
    sudo sed -i "\\#^[^#]*UUID=${MEDIA_DISK_UUID}[[:space:]]\\+${MEDIA_MOUNT_DIR}[[:space:]]#d" /etc/fstab
    echo "[+] Backup fstab: /etc/fstab.home-services.bak"
fi

if [[ -d "$BASE_DIR" ]]; then
    echo "[i] Usuwam ${BASE_DIR}..."
    sudo rm -rf "$BASE_DIR"
else
    echo "[i] ${BASE_DIR} juz nie istnieje."
fi

echo
echo "Gotowe. ${BASE_DIR} zostal usuniety."
echo "Obrazy Dockera nie zostaly skasowane. Jesli chcesz je tez usunac, uruchom:"
echo "sudo docker image prune -a"
