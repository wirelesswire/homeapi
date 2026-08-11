#!/usr/bin/env bash

set -Eeuo pipefail

BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${BASE_DIR}/.env"
COMPOSE=(docker compose --env-file "$ENV_FILE" -f "${BASE_DIR}/compose.yaml")

[[ -f "$ENV_FILE" && -f "${BASE_DIR}/compose.yaml" ]] || { echo "Nie znaleziono deploymentu w ${BASE_DIR}." >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

usage() {
    echo "Uzycie: $0 {status|diagnose|start|stop|update|uninstall|purge}"
}

status() {
    "${COMPOSE[@]}" ps
    echo
    docker exec tailscale tailscale status || true
    echo
    systemctl --no-pager --full status home-services.service home-services-dhcp-metrics.timer || true
}

diagnose() {
    echo "=== Siec ==="
    ip -4 address show dev "$INTERFACE" || true
    ip -4 route show || true
    echo "=== Porty DNS/DHCP/monitoring ==="
    sudo ss -lntup | awk 'NR == 1 || /:53 |:67 |:3000 |:8096 |:9002 |:9090 |:9100 |:9115 |:9617 /'
    echo "=== Kontenery ==="
    "${COMPOSE[@]}" ps
    echo "=== Ostatnie logi krytycznych uslug ==="
    "${COMPOSE[@]}" logs --tail=80 pihole tailscale prometheus grafana
    echo "=== Tailscale ==="
    docker exec tailscale tailscale status || true
    echo "=== Targety Prometheusa ==="
    curl -fsS 'http://127.0.0.1:9090/api/v1/targets?state=active' 2>/dev/null || true
    if command -v nmap >/dev/null 2>&1; then
        echo "=== Serwery DHCP widoczne w LAN ==="
        sudo timeout 15 nmap --script broadcast-dhcp-discover -e "$INTERFACE" 2>/dev/null || true
    else
        echo "[i] nmap nie jest zainstalowany; pomijam wykrywanie drugiego DHCP."
    fi
}

uninstall_stack() {
    sudo systemctl disable --now home-services-dhcp-metrics.timer home-services.service 2>/dev/null || true
    "${COMPOSE[@]}" down --remove-orphans || true
    sudo rm -f /etc/systemd/system/home-services.service \
        /etc/systemd/system/home-services-dhcp-metrics.service \
        /etc/systemd/system/home-services-dhcp-metrics.timer \
        /etc/modules-load.d/home-services-tun.conf
    sudo systemctl daemon-reload
    echo "Uslugi usuniete. Dane pozostaly w ${BASE_DIR}."
}

case "${1:-}" in
    status) status ;;
    diagnose) diagnose ;;
    start) sudo systemctl start home-services.service ;;
    stop) sudo systemctl stop home-services.service ;;
    update)
        "${COMPOSE[@]}" pull
        sudo systemctl restart home-services.service
        ;;
    uninstall) uninstall_stack ;;
    purge)
        resolved_base="$(realpath -m "$BASE_DIR")"
        [[ "$(basename -- "$resolved_base")" == "home-services" && ${#resolved_base} -gt 15 ]] || { echo "Odmawiam usuniecia niebezpiecznej sciezki: ${resolved_base}" >&2; exit 1; }
        read -r -p "Wpisz USUN-DANE, aby bezpowrotnie usunac ${BASE_DIR}: " confirmation
        [[ "$confirmation" == "USUN-DANE" ]] || { echo "Anulowano."; exit 0; }
        uninstall_stack
        cd /
        sudo rm -rf --one-file-system "$resolved_base"
        echo "Usunieto ${BASE_DIR}. Montowane media nie zostaly usuniete."
        ;;
    *) usage; exit 2 ;;
esac
