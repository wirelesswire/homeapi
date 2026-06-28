#!/bin/bash

set -euo pipefail

# --- KONFIGURACJA ---
BASE_DIR="${HOME}/home-services"
PIHOLE_DIR="${BASE_DIR}/pihole"
TAILSCALE_DIR="${BASE_DIR}/tailscale"
JELLYFIN_DIR="${BASE_DIR}/jellyfin"
PASSWORD="admin"
TIMEZONE="Europe/Warsaw"

INTERFACE="${INTERFACE:-}"
PI_IP_CIDR="192.168.1.14/24"
ROUTER_IP="192.168.1.1"
DHCP_START="192.168.1.20"
DHCP_END="192.168.1.250"
UPSTREAM_DNS_1="1.1.1.1"
UPSTREAM_DNS_2="8.8.8.8"
TAILSCALE_HOSTNAME="raspberry-home"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
JELLYFIN_HTTP_PORT="8096"
JELLYFIN_HTTPS_PORT="8920"

MEDIA_DISK_UUID="010A-F2E7"
MEDIA_DISK_TYPE="exfat"
MEDIA_MOUNT_DIR="/mnt/Expansion"
JELLYFIN_MEDIA_CONTAINER_DIR="/media"

# --- TWOJE STATYCZNE URZADZENIA ---
STATIC_IPS=(
    "10:5B:AD:A1:55:A9,192.168.1.15,laptop"
    "50:91:E2:21:BA:17,192.168.1.12,stacjonarny"
    "00:11:22:33:44:55,192.168.1.7,telewizor"
)

require_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "[!] Brakuje polecenia: $command_name"
        exit 1
    fi
}

fail() {
    echo "[!] $1"
    exit 1
}

validate_ip() {
    local ip="$1"
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi

    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    for octet in "$o1" "$o2" "$o3" "$o4"; do
        if (( octet < 0 || octet > 255 )); then
            return 1
        fi
    done
}

validate_cidr() {
    local cidr="$1"
    if [[ ! "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
        return 1
    fi

    local ip_part="${cidr%/*}"
    validate_ip "$ip_part"
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

ip_to_int() {
    local ip="$1"
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    echo $(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
}

same_subnet_24() {
    local ip_a="$1"
    local ip_b="$2"
    [[ "${ip_a%.*}" == "${ip_b%.*}" ]]
}

select_interface() {
    if [[ -n "$INTERFACE" ]]; then
        echo "[i] Uzywam interfejsu z INTERFACE=${INTERFACE}"
    else
        echo "Dostepne interfejsy sieciowe:"
        ip -o link show | awk -F': ' '{print " - " $2}'
        echo
        read -r -p "Podaj interfejs dla statycznego IP i DHCP Pi-hole, np. eth0 albo wlan0: " INTERFACE
    fi

    [[ -n "$INTERFACE" ]] || fail "Nie podano interfejsu."

    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        fail "Interfejs '$INTERFACE' nie istnieje na tej malinie."
    fi
}

ask_tailscale_authkey() {
    if [[ -n "$TAILSCALE_AUTHKEY" ]]; then
        return
    fi

    echo
    echo "Tailscale auth key jest opcjonalny, ale bez niego kontener moze byc szary/offline, dopoki nie zalogujesz go recznie."
    echo "Klucz utworzysz w panelu Tailscale jako ephemeral=false/reusable, jesli chcesz wielokrotnie odpalac ten skrypt."
    read -r -p "Wklej TAILSCALE_AUTHKEY albo zostaw puste i nacisnij Enter: " TAILSCALE_AUTHKEY
}

ensure_network_values() {
    validate_cidr "$PI_IP_CIDR" || fail "PI_IP_CIDR musi miec format np. 192.168.1.14/24"
    validate_ip "$ROUTER_IP" || fail "ROUTER_IP nie jest poprawnym adresem IPv4"
    validate_ip "$DHCP_START" || fail "DHCP_START nie jest poprawnym adresem IPv4"
    validate_ip "$DHCP_END" || fail "DHCP_END nie jest poprawnym adresem IPv4"
    validate_ip "$UPSTREAM_DNS_1" || fail "UPSTREAM_DNS_1 nie jest poprawnym adresem IPv4"
    validate_ip "$UPSTREAM_DNS_2" || fail "UPSTREAM_DNS_2 nie jest poprawnym adresem IPv4"
    validate_port "$JELLYFIN_HTTP_PORT" || fail "JELLYFIN_HTTP_PORT musi byc portem 1-65535"
    validate_port "$JELLYFIN_HTTPS_PORT" || fail "JELLYFIN_HTTPS_PORT musi byc portem 1-65535"

    local pi_ip="${PI_IP_CIDR%/*}"
    local start_int end_int pi_int router_int
    start_int="$(ip_to_int "$DHCP_START")"
    end_int="$(ip_to_int "$DHCP_END")"
    pi_int="$(ip_to_int "$pi_ip")"
    router_int="$(ip_to_int "$ROUTER_IP")"

    (( start_int <= end_int )) || fail "DHCP_START musi byc mniejszy lub rowny DHCP_END"
    same_subnet_24 "$pi_ip" "$ROUTER_IP" || fail "Malina i Funbox musza byc w tej samej podsieci /24"
    same_subnet_24 "$pi_ip" "$DHCP_START" || fail "DHCP_START musi byc w tej samej podsieci /24 co malina"
    same_subnet_24 "$pi_ip" "$DHCP_END" || fail "DHCP_END musi byc w tej samej podsieci /24 co malina"

    (( pi_int < start_int || pi_int > end_int )) || fail "Adres maliny nie moze byc w puli DHCP"
    (( router_int < start_int || router_int > end_int )) || fail "Adres Funboxa nie moze byc w puli DHCP"
}

ensure_static_reservations_valid() {
    local pi_ip="${PI_IP_CIDR%/*}"
    local pi_int router_int reservation_mac reservation_ip reservation_host reservation_int
    pi_int="$(ip_to_int "$pi_ip")"
    router_int="$(ip_to_int "$ROUTER_IP")"

    for entry in "${STATIC_IPS[@]}"; do
        IFS=',' read -r reservation_mac reservation_ip reservation_host <<< "$entry"

        [[ -n "$reservation_mac" && -n "$reservation_ip" && -n "$reservation_host" ]] || fail "Nieprawidlowy wpis STATIC_IPS: $entry"
        validate_ip "$reservation_ip" || fail "Rezerwacja ma niepoprawne IP: $entry"
        same_subnet_24 "$pi_ip" "$reservation_ip" || fail "Rezerwacja jest poza podsiecia maliny: $entry"

        reservation_int="$(ip_to_int "$reservation_ip")"
        (( reservation_int != pi_int )) || fail "Rezerwacja koliduje z adresem maliny: $entry"
        (( reservation_int != router_int )) || fail "Rezerwacja koliduje z adresem Funboxa: $entry"
    done
}

configure_static_ip_with_nmcli() {
    local connection_name

    if ! command -v nmcli >/dev/null 2>&1; then
        return 1
    fi

    connection_name="$(nmcli -t -f GENERAL.CONNECTION device show "$INTERFACE" | sed 's/^GENERAL.CONNECTION://')"
    if [[ -z "$connection_name" || "$connection_name" == "--" ]]; then
        echo "[!] NetworkManager nie pokazuje aktywnego polaczenia dla ${INTERFACE}."
        echo "    Dostepne polaczenia:"
        nmcli con show
        echo
        read -r -p "Podaj nazwe polaczenia NetworkManager dla ${INTERFACE}: " connection_name
    fi

    [[ -n "$connection_name" && "$connection_name" != "--" ]] || fail "Nie podano nazwy polaczenia NetworkManager."

    sudo nmcli con mod "$connection_name" ipv4.addresses "$PI_IP_CIDR"
    sudo nmcli con mod "$connection_name" ipv4.gateway "$ROUTER_IP"
    sudo nmcli con mod "$connection_name" ipv4.dns "${ROUTER_IP} ${UPSTREAM_DNS_1} ${UPSTREAM_DNS_2}"
    sudo nmcli con mod "$connection_name" ipv4.method manual
    sudo nmcli con mod "$connection_name" connection.autoconnect yes

    echo "[+] Ustawiono statyczne IPv4 przez NetworkManager"
    echo "    Interfejs: ${INTERFACE}"
    echo "    Polaczenie: ${connection_name}"
    echo "    IP: ${PI_IP_CIDR}"
    echo "    Brama: ${ROUTER_IP}"
    echo
    echo "[i] Aktywuje polaczenie. Jesli laczysz sie po SSH przez ten interfejs, sesja moze sie na chwile rozlaczyc."
    sudo nmcli con up "$connection_name"
}

append_dhcpcd_config() {
    local tmp_conf
    tmp_conf="$(mktemp)"

    sudo awk '
        /^# home-services static ip start$/ { skip = 1; next }
        /^# home-services static ip end$/ { skip = 0; next }
        skip == 0 { print }
    ' /etc/dhcpcd.conf > "$tmp_conf"

    cat >> "$tmp_conf" <<EOF

# home-services static ip start
interface ${INTERFACE}
static ip_address=${PI_IP_CIDR}
static routers=${ROUTER_IP}
static domain_name_servers=${ROUTER_IP} ${UPSTREAM_DNS_1} ${UPSTREAM_DNS_2}
# home-services static ip end
EOF

    sudo cp /etc/dhcpcd.conf /etc/dhcpcd.conf.home-services.bak
    sudo cp "$tmp_conf" /etc/dhcpcd.conf
    rm -f "$tmp_conf"

    echo "[+] Ustawiono statyczne IP w /etc/dhcpcd.conf"

    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^dhcpcd\.service'; then
        sudo systemctl enable dhcpcd >/dev/null 2>&1 || true
        sudo systemctl restart dhcpcd || true
    elif command -v dhcpcd >/dev/null 2>&1; then
        sudo dhcpcd -n "$INTERFACE" || true
    fi

    if ! ip -4 addr show "$INTERFACE" | grep -q "${PI_IP_CIDR%/*}"; then
        echo "[i] Nadaje IPv4 od razu, bez czekania na restart uslugi."
        sudo ip addr add "$PI_IP_CIDR" dev "$INTERFACE" 2>/dev/null || true
        sudo ip route replace default via "$ROUTER_IP" dev "$INTERFACE"
    fi
}

configure_static_ip() {
    if configure_static_ip_with_nmcli; then
        return
    fi

    echo "[i] Nie znaleziono nmcli, uzywam starej metody przez /etc/dhcpcd.conf"
    append_dhcpcd_config
}

ensure_tailscale_tun() {
    if [[ -e /dev/net/tun ]]; then
        echo "[+] /dev/net/tun istnieje"
        return
    fi

    echo "[i] Przygotowuje /dev/net/tun dla Tailscale..."
    sudo modprobe tun 2>/dev/null || true
    sudo mkdir -p /dev/net

    if [[ ! -e /dev/net/tun ]]; then
        sudo mknod /dev/net/tun c 10 200
        sudo chmod 600 /dev/net/tun
    fi

    if [[ -e /dev/net/tun ]]; then
        echo "[+] /dev/net/tun gotowe"
    else
        echo "[!] /dev/net/tun nadal nie istnieje. Tailscale moze nie wstac poprawnie."
    fi
}

ensure_media_disk_mount() {
    require_command findmnt
    require_command blkid

    if ! blkid -U "$MEDIA_DISK_UUID" >/dev/null 2>&1; then
        echo "[!] Nie widze dysku UUID=${MEDIA_DISK_UUID}."
        echo "    Jellyfin wystartuje, ale katalog ${MEDIA_MOUNT_DIR} moze byc pusty."
        echo "    Sprawdz dysk poleceniem: lsblk -f"
        sudo mkdir -p "$MEDIA_MOUNT_DIR"
        return
    fi

    sudo mkdir -p "$MEDIA_MOUNT_DIR"

    local fstab_line="UUID=${MEDIA_DISK_UUID} ${MEDIA_MOUNT_DIR} ${MEDIA_DISK_TYPE} defaults,nofail,uid=1000,gid=1000,umask=002,iocharset=utf8 0 0"
    if ! grep -Eq "^[^#]*UUID=${MEDIA_DISK_UUID}[[:space:]]+${MEDIA_MOUNT_DIR}[[:space:]]" /etc/fstab; then
        echo "$fstab_line" | sudo tee -a /etc/fstab >/dev/null
        echo "[+] Dodano automatyczne montowanie dysku do /etc/fstab"
    else
        echo "[i] Wpis dla dysku UUID=${MEDIA_DISK_UUID} juz istnieje w /etc/fstab"
    fi

    if ! findmnt -rn "$MEDIA_MOUNT_DIR" >/dev/null 2>&1; then
        sudo mount "$MEDIA_MOUNT_DIR"
    fi

    if findmnt -rn "$MEDIA_MOUNT_DIR" >/dev/null 2>&1; then
        echo "[+] Dysk zamontowany w ${MEDIA_MOUNT_DIR}"
    else
        echo "[!] Nie udalo sie zamontowac dysku ${MEDIA_DISK_UUID}."
        echo "    Sprobuj: sudo mount ${MEDIA_MOUNT_DIR}"
    fi
}

write_static_dhcp_config() {
    local static_conf="$1"

    {
        echo "# Wygenerowane przez skrypt"
        for entry in "${STATIC_IPS[@]}"; do
            IFS=',' read -r reservation_mac reservation_ip reservation_host <<< "$entry"
            echo "dhcp-host=${reservation_mac},id:*,${reservation_ip},${reservation_host}"
        done
    } > "$static_conf"
}

write_static_dhcp_env_block() {
    local entry reservation_mac reservation_ip reservation_host

    echo "      FTLCONF_misc_dnsmasq_lines: |-"
    for entry in "${STATIC_IPS[@]}"; do
        IFS=',' read -r reservation_mac reservation_ip reservation_host <<< "$entry"
        echo "        dhcp-host=${reservation_mac},id:*,${reservation_ip},${reservation_host}"
    done
}

write_compose_file() {
    cat > "${BASE_DIR}/docker-compose.yml" <<EOF
services:
  pihole:
    container_name: pihole
    image: pihole/pihole:latest
    network_mode: host
    environment:
      TZ: '${TIMEZONE}'
      FTLCONF_webserver_api_password: '${PASSWORD}'
      FTLCONF_dns_listeningMode: 'ALL'
      FTLCONF_dns_upstreams: '${UPSTREAM_DNS_1};${UPSTREAM_DNS_2}'
      FTLCONF_dhcp_active: 'true'
      FTLCONF_dhcp_start: '${DHCP_START}'
      FTLCONF_dhcp_end: '${DHCP_END}'
      FTLCONF_dhcp_router: '${ROUTER_IP}'
$(write_static_dhcp_env_block)
      INTERFACE: '${INTERFACE}'
    volumes:
      - '${PIHOLE_DIR}/etc-pihole:/etc/pihole'
      - '${PIHOLE_DIR}/etc-dnsmasq.d:/etc/dnsmasq.d'
    cap_add:
      - NET_ADMIN
      - NET_RAW
      - SYS_TIME
      - SYS_NICE
    restart: unless-stopped

  tailscale:
    container_name: tailscale
    image: tailscale/tailscale:latest
    hostname: '${TAILSCALE_HOSTNAME}'
    network_mode: host
    environment:
      TS_AUTHKEY: '${TAILSCALE_AUTHKEY}'
      TS_STATE_DIR: /var/lib/tailscale
      TS_USERSPACE: 'false'
      TS_ACCEPT_DNS: 'false'
      TS_EXTRA_ARGS: '--accept-dns=false'
    volumes:
      - '${TAILSCALE_DIR}/state:/var/lib/tailscale'
    devices:
      - '/dev/net/tun:/dev/net/tun'
    cap_add:
      - NET_ADMIN
      - NET_RAW
      - SYS_MODULE
    restart: unless-stopped

  jellyfin:
    container_name: jellyfin
    image: jellyfin/jellyfin:latest
    environment:
      TZ: '${TIMEZONE}'
    ports:
      - '${JELLYFIN_HTTP_PORT}:8096'
      - '${JELLYFIN_HTTPS_PORT}:8920'
      - '7359:7359/udp'
      - '1900:1900/udp'
    volumes:
      - '${JELLYFIN_DIR}/config:/config'
      - '${JELLYFIN_DIR}/cache:/cache'
      - '${MEDIA_MOUNT_DIR}:${JELLYFIN_MEDIA_CONTAINER_DIR}:ro'
    restart: unless-stopped
EOF
}

main() {
    require_command docker
    require_command ip
    require_command sudo

    select_interface
    ask_tailscale_authkey
    ensure_network_values
    ensure_static_reservations_valid

    local pi_ip="${PI_IP_CIDR%/*}"
    local static_conf="${PIHOLE_DIR}/etc-dnsmasq.d/04-static-dhcp.conf"

    echo "--- 1. Ustawianie statycznego IP Maliny ---"
    configure_static_ip

    echo "--- 2. Przygotowanie dysku dla Jellyfina ---"
    ensure_media_disk_mount

    echo "--- 3. Przygotowanie Tailscale ---"
    ensure_tailscale_tun

    echo "--- 4. Przygotowanie folderow projektu ---"
    mkdir -p "${PIHOLE_DIR}/etc-pihole"
    mkdir -p "${PIHOLE_DIR}/etc-dnsmasq.d"
    mkdir -p "${TAILSCALE_DIR}/state"
    mkdir -p "${JELLYFIN_DIR}/config"
    mkdir -p "${JELLYFIN_DIR}/cache"

    echo "--- 5. Generowanie rezerwacji DHCP ---"
    write_static_dhcp_config "$static_conf"

    echo "--- 6. Generowanie docker-compose.yml ---"
    write_compose_file

    echo "--- 7. Uruchamianie uslug ---"
    cd "${BASE_DIR}"
    sudo docker compose down --remove-orphans
    sudo docker compose up -d

    echo
    echo "SUKCES"
    echo "Interfejs maliny: ${INTERFACE}"
    echo "Adres maliny: ${pi_ip}"
    echo "Panel Pi-hole: http://${pi_ip}/admin"
    echo "Jellyfin: http://${pi_ip}:${JELLYFIN_HTTP_PORT}"
    echo "Media Jellyfin w kontenerze: ${JELLYFIN_MEDIA_CONTAINER_DIR}"
    echo "Dysk na malinie: ${MEDIA_MOUNT_DIR}"
    echo "DHCP Pi-hole: WLACZONE (${DHCP_START} - ${DHCP_END})"
    echo "Brama dla klientow: ${ROUTER_IP}"
    echo "DNS upstream: ${UPSTREAM_DNS_1}, ${UPSTREAM_DNS_2}"
    echo
    if [[ -z "$TAILSCALE_AUTHKEY" ]]; then
        echo "TAILSCALE: kontener uruchomiony bez klucza autoryzacyjnego."
        echo "          Jesli w panelu jest szary/offline, zaloguj go:"
        echo "          sudo docker exec -it tailscale tailscale up --accept-dns=false --hostname=${TAILSCALE_HOSTNAME}"
    else
        echo "TAILSCALE: kontener uruchomiony z podanym kluczem autoryzacyjnym."
    fi
    echo "Status Tailscale sprawdzisz:"
    echo "sudo docker exec tailscale tailscale status"
    echo
    echo "KOLEJNOSC MIGRACJI:"
    echo "1. Sprawdz, czy panel Pi-hole odpowiada pod http://${pi_ip}/admin"
    echo "2. Sprawdz, czy Jellyfin odpowiada pod http://${pi_ip}:${JELLYFIN_HTTP_PORT}"
    echo "3. W Jellyfin dodaj biblioteke z katalogu ${JELLYFIN_MEDIA_CONTAINER_DIR}"
    echo "4. Sprawdz, czy Pi-hole rozwiazuje DNS i ma internet"
    echo "5. Dopiero potem wylacz DHCP w Funboxie"
    echo "6. Odnow dzierzawe IP na urzadzeniach w domu"
}

main "$@"
