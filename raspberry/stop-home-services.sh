#!/bin/bash

set -euo pipefail

BASE_DIR="${HOME}/home-services"

if [[ ! -f "${BASE_DIR}/docker-compose.yml" ]]; then
    echo "[!] Nie znaleziono ${BASE_DIR}/docker-compose.yml"
    echo "    Nie ma czego zatrzymac albo uslugi sa w innym katalogu."
    exit 1
fi

require_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "[!] Brakuje polecenia: $command_name"
        exit 1
    fi
}

require_command docker
require_command sudo

cd "$BASE_DIR"

echo "[i] Zatrzymuje kontenery z ${BASE_DIR}..."
sudo docker compose down --remove-orphans

echo
echo "Gotowe. Kontenery zostaly zatrzymane."
echo "Dane i konfiguracja zostaja w ${BASE_DIR}."
