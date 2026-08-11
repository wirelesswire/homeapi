#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ENV="${ENV_FILE:-${SCRIPT_DIR}/.env}"

fail() { printf '[!] %s\n' "$*" >&2; exit 1; }
info() { printf '[i] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Brakuje polecenia: $1"
}

[[ -f "$SOURCE_ENV" ]] || fail "Brakuje ${SOURCE_ENV}. Skopiuj .env.example do .env i uzupelnij sekrety."

set -a
# shellcheck disable=SC1090
source "$SOURCE_ENV"
set +a

BASE_DIR="${BASE_DIR:-${HOME}/home-services}"

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

[[ -e "/sys/class/net/${INTERFACE}" ]] || fail "Interfejs ${INTERFACE} nie istnieje."

configure_networkmanager() {
    local connection_name
    connection_name="$(nmcli -g GENERAL.CONNECTION device show "$INTERFACE" | head -n1)"
    [[ -n "$connection_name" && "$connection_name" != "--" ]] || fail "Brak aktywnego polaczenia NetworkManager dla ${INTERFACE}."

    sudo nmcli connection modify "$connection_name" \
        ipv4.method manual \
        ipv4.addresses "$PI_IP_CIDR" \
        ipv4.gateway "$ROUTER_IP" \
        ipv4.dns "${UPSTREAM_DNS_1} ${UPSTREAM_DNS_2}" \
        ipv4.ignore-auto-dns yes \
        connection.autoconnect yes
    ok "Statyczne IP zapisane w NetworkManager (${connection_name})."
    if ! ip -4 address show dev "$INTERFACE" | grep -Fq "inet ${PI_IP_CIDR}"; then
        info "Aktywacja polaczenia moze chwilowo przerwac SSH."
        sudo nmcli connection up "$connection_name"
    fi
}

configure_dhcpcd() {
    local config=/etc/dhcpcd.conf tmp
    [[ -f "$config" ]] || fail "Aktywny dhcpcd nie ma pliku ${config}."
    tmp="$(mktemp)"
    sudo awk '
        /^# home-services managed start$/ { skip=1; next }
        /^# home-services managed end$/ { skip=0; next }
        !skip { print }
    ' "$config" > "$tmp"
    cat >> "$tmp" <<EOF

# home-services managed start
interface ${INTERFACE}
static ip_address=${PI_IP_CIDR}
static routers=${ROUTER_IP}
static domain_name_servers=${UPSTREAM_DNS_1} ${UPSTREAM_DNS_2}
# home-services managed end
EOF
    [[ -f "${config}.home-services.bak" ]] || sudo cp -a "$config" "${config}.home-services.bak"
    sudo install -m 644 "$tmp" "$config"
    rm -f "$tmp"
    if ! ip -4 address show dev "$INTERFACE" | grep -Fq "inet ${PI_IP_CIDR}"; then
        sudo systemctl restart dhcpcd
    fi
    ok "Statyczne IP zapisane w dhcpcd."
}

remove_legacy_static_ip_service() {
    if systemctl list-unit-files home-services-static-ip.service --no-legend 2>/dev/null | grep -q home-services-static-ip; then
        info "Usuwam stara usluge, ktora recznie nadpisywala IP i resolv.conf."
        sudo systemctl disable --now home-services-static-ip.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/home-services-static-ip.service /usr/local/sbin/home-services-static-ip.sh
        sudo systemctl daemon-reload
    fi
}

configure_static_ip() {
    if systemctl is-active --quiet NetworkManager && command -v nmcli >/dev/null 2>&1; then
        configure_networkmanager
    elif systemctl is-active --quiet dhcpcd; then
        configure_dhcpcd
    else
        fail "Nie wykryto aktywnego NetworkManager ani dhcpcd. Nie zmieniam sieci recznie."
    fi
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
}

ensure_media_disk_mount() {
    require_command blkid
    require_command findmnt
    sudo install -d -m 755 "$MEDIA_MOUNT_DIR"
    if ! blkid -U "$MEDIA_DISK_UUID" >/dev/null 2>&1; then
        info "Dysk UUID=${MEDIA_DISK_UUID} nie jest widoczny; Jellyfin wystartuje z pustym katalogiem mediow."
        return
    fi
    local fstab_line="UUID=${MEDIA_DISK_UUID} ${MEDIA_MOUNT_DIR} ${MEDIA_DISK_TYPE} defaults,nofail,x-systemd.automount,uid=1000,gid=1000,umask=002 0 0"
    if ! grep -Eq "^[^#]*UUID=${MEDIA_DISK_UUID}[[:space:]]+${MEDIA_MOUNT_DIR}[[:space:]]" /etc/fstab; then
        sudo cp -a /etc/fstab /etc/fstab.home-services.bak
        printf '%s\n' "$fstab_line" | sudo tee -a /etc/fstab >/dev/null
    fi
    if ! findmnt -rn "$MEDIA_MOUNT_DIR" >/dev/null 2>&1; then
        sudo mount "$MEDIA_MOUNT_DIR" || info "Nie udalo sie zamontowac ${MEDIA_MOUNT_DIR}."
    fi
}

install_tun_boot_support() {
    printf 'tun\n' | sudo tee /etc/modules-load.d/home-services-tun.conf >/dev/null
    sudo modprobe tun
    [[ -c /dev/net/tun ]] || fail "/dev/net/tun nie jest dostepne po zaladowaniu modulu tun."
    ok "Modul TUN jest gotowy i bedzie ladowany przy starcie."
}

install_systemd_units() {
    sudo tee /etc/systemd/system/home-services.service >/dev/null <<EOF
[Unit]
Description=Home services Docker Compose stack
Requires=docker.service
Wants=network-online.target
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${BASE_DIR}
ExecStartPre=/sbin/modprobe tun
ExecStartPre=/usr/bin/test -c /dev/net/tun
ExecStart=/usr/bin/docker compose --env-file ${BASE_DIR}/.env -f ${BASE_DIR}/compose.yaml up -d --remove-orphans
ExecStop=/usr/bin/docker compose --env-file ${BASE_DIR}/.env -f ${BASE_DIR}/compose.yaml down --remove-orphans
TimeoutStartSec=300
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
    sudo systemctl enable home-services.service home-services-dhcp-metrics.timer >/dev/null
    ok "Uslugi systemd zostaly zainstalowane."
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
        return
    fi
    if grep -q '<EnableMetrics>false</EnableMetrics>' "$config"; then
        sudo sed -i 's#<EnableMetrics>false</EnableMetrics>#<EnableMetrics>true</EnableMetrics>#' "$config"
        sudo docker compose --env-file "$BASE_DIR/.env" -f "$BASE_DIR/compose.yaml" restart jellyfin
        ok "Wlaczono natywne metryki Jellyfin."
    fi
}

scrub_tailscale_authkey() {
    [[ -n "${TAILSCALE_AUTHKEY:-}" ]] || return
    local attempt
    for attempt in $(seq 1 30); do
        if sudo docker exec tailscale tailscale status >/dev/null 2>&1; then
            sudo sed -i 's/^TAILSCALE_AUTHKEY=.*/TAILSCALE_AUTHKEY=/' "$BASE_DIR/.env"
            if [[ -w "$SOURCE_ENV" ]]; then
                sed -i 's/^TAILSCALE_AUTHKEY=.*/TAILSCALE_AUTHKEY=/' "$SOURCE_ENV"
            fi
            ok "Tailscale jest zalogowany; klucz jednorazowy usunieto z pliku .env."
            return
        fi
        sleep 2
    done
    info "Tailscale nie potwierdzil logowania; klucz pozostaje w .env do kolejnej proby."
}

warn_about_existing_dhcp() {
    info "Przed wylaczeniem DHCP w Funboxie przetestuj Pi-hole na jednym kliencie."
    if command -v nmap >/dev/null 2>&1; then
        info "Wynik wykrywania serwerow DHCP (obecny Funbox jest oczekiwany podczas migracji):"
        sudo timeout 15 nmap --script broadcast-dhcp-discover -e "$INTERFACE" 2>/dev/null || true
    else
        info "Zainstaluj nmap, aby komenda diagnose mogla wykrywac drugi serwer DHCP."
    fi
}

main() {
    remove_legacy_static_ip_service
    configure_static_ip
    ensure_media_disk_mount
    install_files
    install_tun_boot_support
    install_systemd_units

    cd "$BASE_DIR"
    sudo docker compose --env-file .env -f compose.yaml config --quiet
    sudo systemctl restart home-services.service
    sudo systemctl start home-services-dhcp-metrics.timer
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
