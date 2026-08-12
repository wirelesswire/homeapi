#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ENV="${ENV_FILE:-${SCRIPT_DIR}/.env}"

fail() { printf '[!] %s\n' "$*" >&2; exit 1; }
info() { printf '[i] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }

INSTALL_MARKER_CREATED=false
cleanup_install_marker() {
    if [[ "${INSTALL_MARKER_CREATED:-false}" == true ]]; then
        sudo rm -f /run/home-services-installing || true
    fi
    return 0
}
report_unhandled_error() {
    local status=$1 line=$2 command=$3
    printf '[!] Nieoczekiwany blad w linii %s: %s (kod %s).\n' "$line" "$command" "$status" >&2
    return "$status"
}
trap cleanup_install_marker EXIT
trap 'report_unhandled_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Brakuje polecenia: $1"
    return 0
}

[[ -f "$SOURCE_ENV" ]] || fail "Brakuje ${SOURCE_ENV}. Skopiuj .env.example do .env i uzupelnij sekrety."

set -a
# shellcheck disable=SC1090
source "$SOURCE_ENV"
set +a

BASE_DIR="${BASE_DIR:-${HOME}/home-services}"

migrate_known_configuration() {
    local old_reservation='50:91:E2:21:BA:17,192.168.1.12,stacjonarny,24h'
    local new_reservation='50:91:E3:21:BA:17,192.168.1.12,stacjonarny,24h'
    if [[ "${DHCP_HOST_2:-}" == "$old_reservation" ]]; then
        if [[ ! -w "$SOURCE_ENV" ]]; then
            fail "Nie moge automatycznie poprawic starej rezerwacji DHCP w ${SOURCE_ENV}."
        fi
        sed -i "s#^DHCP_HOST_2=${old_reservation}\$#DHCP_HOST_2=${new_reservation}#" "$SOURCE_ENV"
        DHCP_HOST_2=$new_reservation
        export DHCP_HOST_2
        ok "Poprawiono rezerwacje PC: 50:91:E3:21:BA:17 -> 192.168.1.12."
    fi
    return 0
}

migrate_known_configuration

require_command docker
require_command ip
require_command systemctl
require_command sudo
require_command awk
docker compose version >/dev/null 2>&1 || fail "Wymagany jest Docker Compose v2."

bash "${SCRIPT_DIR}/validate-config.sh" "$SOURCE_ENV"

if [[ "$(uname -m)" != "aarch64" && "$(uname -m)" != "arm64" ]]; then
    info "Architektura $(uname -m) nie jest 64-bit ARM; obrazy musza obslugiwac te platforme."
fi

detect_network_interfaces() {
    ETH_INTERFACE=${ETH_INTERFACE:-eth0}
    WLAN_INTERFACE=${WLAN_INTERFACE:-wlan0}
    if [[ ! -e "/sys/class/net/${ETH_INTERFACE}" && ! -e "/sys/class/net/${WLAN_INTERFACE}" ]]; then
        fail "Nie znaleziono ${ETH_INTERFACE} ani ${WLAN_INTERFACE}."
    fi
    export ETH_INTERFACE WLAN_INTERFACE
    return 0
}

write_networkd_link_config() {
    local interface_name=$1
    [[ -e "/sys/class/net/${interface_name}" ]] || return 0
    sudo tee "/etc/systemd/network/05-home-services-${interface_name}.network" >/dev/null <<EOF
# Managed by home-services. IPv4 is assigned by home-services-network.service.
[Match]
Name=${interface_name}

[Network]
DHCP=no
LinkLocalAddressing=ipv6
IPv6AcceptRA=yes

[Link]
RequiredForOnline=no
EOF
    return 0
}

configure_network_failover() {
    systemctl is-active --quiet systemd-networkd || fail "Automatyczny failover wymaga aktywnego systemd-networkd."
    detect_network_interfaces

    local old_network_file
    for old_network_file in /etc/systemd/network/05-home-services-*.network; do
        [[ -e "$old_network_file" ]] || continue
        sudo rm -f "$old_network_file"
    done
    write_networkd_link_config "$ETH_INTERFACE"
    write_networkd_link_config "$WLAN_INTERFACE"
    sudo cp "${SCRIPT_DIR}/network-failover.sh" /usr/local/sbin/home-services-network.sh
    sudo chmod 755 /usr/local/sbin/home-services-network.sh
    ok "Skonfigurowano automatyczny failover: ${ETH_INTERFACE} -> ${WLAN_INTERFACE}."
    info "Zmiany sieci zostana zastosowane dopiero przy restarcie; biezace SSH pozostaje bez zmian."
    return 0
}

remove_legacy_static_ip_service() {
    if systemctl list-unit-files home-services-static-ip.service --no-legend 2>/dev/null | grep -q home-services-static-ip; then
        info "Usuwam stara usluge, ktora recznie nadpisywala IP i resolv.conf."
        sudo systemctl disable --now home-services-static-ip.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/home-services-static-ip.service /usr/local/sbin/home-services-static-ip.sh
        sudo systemctl daemon-reload
    fi
    return 0
}

install_files() {
    sudo install -d -m 755 "$BASE_DIR" "$BASE_DIR/monitoring" \
        "$BASE_DIR/pihole/etc-pihole" "$BASE_DIR/tailscale/state" \
        "$BASE_DIR/jellyfin/config" "$BASE_DIR/jellyfin/cache" \
        "$BASE_DIR/grafana" "$BASE_DIR/prometheus" "$BASE_DIR/monitoring/textfile"
    sudo cp "${SCRIPT_DIR}/compose.yaml" "$BASE_DIR/compose.yaml"
    sudo cp "${SCRIPT_DIR}/home-services.sh" "$BASE_DIR/home-services.sh"
    sudo cp -a "${SCRIPT_DIR}/monitoring/." "$BASE_DIR/monitoring/"
    sudo cp "$SOURCE_ENV" "$BASE_DIR/.env"
    sudo chmod 700 "$BASE_DIR/tailscale/state"
    sudo chmod 600 "$BASE_DIR/.env"
    sudo chmod 755 "$BASE_DIR/home-services.sh" "$BASE_DIR/monitoring/dhcp-metrics.sh"
    sudo chown -R 472:472 "$BASE_DIR/grafana"
    sudo chown -R 65534:65534 "$BASE_DIR/prometheus"
    ok "Pliki zainstalowane w ${BASE_DIR}."
    return 0
}

ensure_media_disk_mount() {
    require_command blkid
    require_command findmnt
    if [[ ! -d "$MEDIA_MOUNT_DIR" ]]; then
        sudo mkdir -p "$MEDIA_MOUNT_DIR"
    fi
    if ! blkid -U "$MEDIA_DISK_UUID" >/dev/null 2>&1; then
        info "Dysk UUID=${MEDIA_DISK_UUID} nie jest widoczny; Jellyfin wystartuje z pustym katalogiem mediow."
        return 0
    fi
    local fstab_line="UUID=${MEDIA_DISK_UUID} ${MEDIA_MOUNT_DIR} ${MEDIA_DISK_TYPE} defaults,nofail,x-systemd.automount,uid=1000,gid=1000,umask=002 0 0"
    if ! grep -Eq "^[^#]*UUID=${MEDIA_DISK_UUID}[[:space:]]+${MEDIA_MOUNT_DIR}[[:space:]]" /etc/fstab; then
        sudo cp -a /etc/fstab /etc/fstab.home-services.bak
        printf '%s\n' "$fstab_line" | sudo tee -a /etc/fstab >/dev/null
    fi
    if ! findmnt -rn "$MEDIA_MOUNT_DIR" >/dev/null 2>&1; then
        sudo mount "$MEDIA_MOUNT_DIR" || info "Nie udalo sie zamontowac ${MEDIA_MOUNT_DIR}."
    fi
    return 0
}

install_tun_boot_support() {
    printf 'tun\n' | sudo tee /etc/modules-load.d/home-services-tun.conf >/dev/null
    sudo modprobe tun
    [[ -c /dev/net/tun ]] || fail "/dev/net/tun nie jest dostepne po zaladowaniu modulu tun."
    ok "Modul TUN jest gotowy i bedzie ladowany przy starcie."
    return 0
}

install_systemd_units() {
    sudo tee /etc/systemd/system/home-services-network.service >/dev/null <<EOF
[Unit]
Description=Select Ethernet or Wi-Fi for the home-services address
After=systemd-networkd.service wpa_supplicant.service
Before=network-online.target home-services.service
Wants=systemd-networkd.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/home-services-network.sh once ${BASE_DIR}/.env
RemainAfterExit=yes
TimeoutStartSec=100

[Install]
WantedBy=multi-user.target
EOF

    sudo tee /etc/systemd/system/home-services-network-monitor.service >/dev/null <<EOF
[Unit]
Description=Monitor Ethernet/Wi-Fi failover for home-services
Requires=home-services-network.service
After=home-services-network.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/home-services-network.sh monitor ${BASE_DIR}/.env
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

    sudo tee /etc/systemd/system/home-services.service >/dev/null <<EOF
[Unit]
Description=Home services Docker Compose stack
Requires=docker.service home-services-network.service
Wants=network-online.target
After=docker.service home-services-network.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${BASE_DIR}
ExecStartPre=/sbin/modprobe tun
ExecStartPre=/usr/bin/test -c /dev/net/tun
ExecStart=/usr/bin/docker compose --env-file ${BASE_DIR}/.env -f ${BASE_DIR}/compose.yaml up -d --remove-orphans
ExecStop=/usr/bin/docker compose --env-file ${BASE_DIR}/.env -f ${BASE_DIR}/compose.yaml down --remove-orphans
TimeoutStartSec=0
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF

    sudo tee /etc/systemd/system/home-services-dhcp-metrics.service >/dev/null <<EOF
[Unit]
Description=Export Pi-hole DHCP lease metrics for node_exporter
After=home-services.service

[Service]
Type=oneshot
EnvironmentFile=${BASE_DIR}/.env
ExecStart=${BASE_DIR}/monitoring/dhcp-metrics.sh ${BASE_DIR}/pihole/etc-pihole/dhcp.leases ${BASE_DIR}/monitoring/textfile/dhcp.prom
User=root
EOF

    sudo tee /etc/systemd/system/home-services-dhcp-metrics.timer >/dev/null <<'EOF'
[Unit]
Description=Refresh Pi-hole DHCP metrics every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable home-services-network.service home-services-network-monitor.service \
        home-services.service home-services-dhcp-metrics.timer >/dev/null
    ok "Uslugi systemd zostaly zainstalowane."
    return 0
}

enable_jellyfin_metrics() {
    local config="${BASE_DIR}/jellyfin/config/config/system.xml"
    local attempt
    for attempt in $(seq 1 30); do
        [[ -f "$config" ]] && break
        sleep 2
    done
    if [[ ! -f "$config" ]]; then
        info "Jellyfin nie utworzyl jeszcze system.xml; metryki mozna wlaczyc ponownym uruchomieniem instalatora."
        return 0
    fi
    if grep -q '<EnableMetrics>false</EnableMetrics>' "$config"; then
        if sudo sed -i 's#<EnableMetrics>false</EnableMetrics>#<EnableMetrics>true</EnableMetrics>#' "$config" && \
           sudo docker compose --env-file "$BASE_DIR/.env" -f "$BASE_DIR/compose.yaml" restart jellyfin; then
            ok "Wlaczono natywne metryki Jellyfin."
        else
            info "Nie udalo sie automatycznie wlaczyc metryk Jellyfin; sam Jellyfin pozostaje uruchomiony."
        fi
    fi
    return 0
}

scrub_tailscale_authkey() {
    [[ -n "${TAILSCALE_AUTHKEY:-}" ]] || return 0
    local attempt
    for ((attempt = 1; attempt <= 30; attempt++)); do
        if sudo docker exec tailscale tailscale status >/dev/null 2>&1; then
            if ! sudo sed -i 's/^TAILSCALE_AUTHKEY=.*/TAILSCALE_AUTHKEY=/' "$BASE_DIR/.env"; then
                info "Tailscale dziala, ale nie udalo sie wyczyscic klucza z zainstalowanego .env."
                return 0
            fi
            if [[ -w "$SOURCE_ENV" ]]; then
                sed -i 's/^TAILSCALE_AUTHKEY=.*/TAILSCALE_AUTHKEY=/' "$SOURCE_ENV" || \
                    info "Nie udalo sie wyczyscic klucza ze zrodlowego .env."
            fi
            ok "Tailscale jest zalogowany; klucz jednorazowy usunieto z pliku .env."
            return 0
        fi
        sleep 2
    done
    info "Tailscale nie potwierdzil logowania; klucz pozostaje w .env do kolejnej proby."
    return 0
}

warn_about_existing_dhcp() {
    local active_interface
    active_interface="$(cat /run/home-services-network-interface 2>/dev/null || ip -4 route show default | awk '{ print $5; exit }')"
    info "Przed wylaczeniem DHCP w Funboxie przetestuj Pi-hole na jednym kliencie."
    if command -v nmap >/dev/null 2>&1; then
        info "Wynik wykrywania serwerow DHCP (obecny Funbox jest oczekiwany podczas migracji):"
        sudo timeout 15 nmap --script broadcast-dhcp-discover -e "$active_interface" 2>/dev/null || true
    else
        info "Zainstaluj nmap, aby komenda diagnose mogla wykrywac drugi serwer DHCP."
    fi
    return 0
}

show_service_failure() {
    local service=$1
    sudo systemctl --no-pager --full status "$service" || true
    sudo journalctl -u "$service" -n 80 --no-pager || true
    return 0
}

configure_grafana_firewall() {
    command -v ufw >/dev/null 2>&1 || return 0
    sudo ufw status 2>/dev/null | grep -q '^Status: active' || return 0
    local lan_subnet="${PI_IP%.*}.0/24"
    sudo ufw allow from "$lan_subnet" to any port "$GRAFANA_PORT" proto tcp comment 'home-services Grafana LAN' >/dev/null
    if [[ -e /sys/class/net/tailscale0 ]]; then
        sudo ufw allow in on tailscale0 to any port "$GRAFANA_PORT" proto tcp comment 'home-services Grafana Tailscale' >/dev/null
    fi
    ok "Firewall UFW dopuszcza Grafane z LAN i Tailscale."
    return 0
}

verify_runtime() {
    local attempt grafana_ready=false
    for ((attempt = 1; attempt <= 30; attempt++)); do
        if curl -fsS "http://127.0.0.1:${GRAFANA_PORT}/api/health" >/dev/null 2>&1; then
            grafana_ready=true
            break
        fi
        sleep 2
    done
    if [[ "$grafana_ready" != true ]]; then
        show_service_failure home-services.service
        sudo docker logs --tail=80 grafana 2>&1 || true
        fail "Grafana nie odpowiada lokalnie na porcie ${GRAFANA_PORT}."
    fi
    if ! sudo ss -ltnH "sport = :${GRAFANA_PORT}" | awk '{print $4}' | grep -Eq '(^|\])0\.0\.0\.0:|^\*:|^\[::\]:'; then
        sudo ss -ltnp "sport = :${GRAFANA_PORT}" || true
        fail "Grafana nie nasluchuje na wszystkich interfejsach."
    fi
    if ! sudo docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' cadvisor | grep -qx healthy; then
        info "cAdvisor jeszcze nie jest healthy; pokazuje ostatni wynik healthchecku."
        sudo docker inspect --format '{{range .State.Health.Log}}{{.Output}}{{end}}' cadvisor 2>/dev/null || true
    fi
    ok "Grafana odpowiada i nasluchuje w LAN; test cAdvisor zostal wykonany."
    return 0
}

main() {
    sudo rm -f /run/home-services-installing
    remove_legacy_static_ip_service
    ensure_media_disk_mount
    install_files
    configure_network_failover
    install_tun_boot_support
    install_systemd_units

    cd "$BASE_DIR"
    sudo docker compose --env-file .env -f compose.yaml config --quiet
    info "Pobieram obrazy kontenerow. Pierwsze uruchomienie moze potrwac kilkanascie minut."
    if ! sudo docker compose --env-file .env -f compose.yaml pull; then
        fail "Nie udalo sie pobrac wszystkich obrazow kontenerow."
    fi
    sudo touch /run/home-services-installing
    INSTALL_MARKER_CREATED=true
    if ! sudo systemctl restart home-services-network.service; then
        show_service_failure home-services-network.service
        fail "Nie udalo sie uruchomic automatycznej konfiguracji sieci."
    fi
    if ! sudo systemctl restart home-services.service; then
        show_service_failure home-services.service
        fail "Nie udalo sie uruchomic kontenerow."
    fi
    sudo rm -f /run/home-services-installing
    INSTALL_MARKER_CREATED=false
    if ! sudo systemctl start home-services-dhcp-metrics.timer; then
        info "Nie udalo sie uruchomic timera metryk DHCP; kontenery pozostaja uruchomione."
    fi
    configure_grafana_firewall
    verify_runtime
    scrub_tailscale_authkey
    enable_jellyfin_metrics
    warn_about_existing_dhcp

    local pi_ip="${PI_IP_CIDR%/*}"
    printf '\nGOTOWE\n'
    printf 'Pi-hole:  http://%s/admin/\n' "$pi_ip"
    printf 'Jellyfin: http://%s:%s\n' "$pi_ip" "$JELLYFIN_HTTP_PORT"
    printf 'Grafana:  http://%s:%s\n' "$pi_ip" "$GRAFANA_PORT"
    printf '\nKolejnosc migracji DHCP:\n'
    printf '1. Sprawdz: %s diagnose\n' "$BASE_DIR/home-services.sh"
    printf '2. Odnow dzierzawe na jednym kliencie i potwierdz DNS=%s oraz brame=%s.\n' "$pi_ip" "$ROUTER_IP"
    printf '3. Wylacz DHCP w Funboxie.\n'
    printf '4. Odnow dzierzawy na pozostalych urzadzeniach.\n'
    printf '5. Po restarcie maliny potwierdz Tailscale: %s status\n' "$BASE_DIR/home-services.sh"
}

main "$@"
