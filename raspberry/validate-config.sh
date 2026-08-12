#!/usr/bin/env bash

set -Eeuo pipefail

ENV_FILE="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/.env}"
[[ -f "$ENV_FILE" ]] || { echo "Brakuje ${ENV_FILE}" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

fail() { printf '[!] %s\n' "$*" >&2; exit 1; }
required=(PI_IP_CIDR PI_IP ROUTER_IP DHCP_START DHCP_END DHCP_NETMASK DHCP_LEASE_TIME UPSTREAM_DNS_1 UPSTREAM_DNS_2 TIMEZONE PIHOLE_PASSWORD GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD TAILSCALE_HOSTNAME DHCP_HOST_1 DHCP_HOST_2 DHCP_HOST_3 MEDIA_MOUNT_DIR MEDIA_DISK_UUID MEDIA_DISK_TYPE JELLYFIN_HTTP_PORT JELLYFIN_HTTPS_PORT GRAFANA_PORT)
for name in "${required[@]}"; do
    [[ -n "${!name:-}" ]] || fail "Brak wymaganej wartosci: ${name}"
done

for interface_name in "${ETH_INTERFACE:-eth0}" "${WLAN_INTERFACE:-wlan0}"; do
    [[ "$interface_name" =~ ^[[:alnum:]_.:-]+$ ]] || fail "Nazwa interfejsu zawiera niedozwolone znaki: ${interface_name}"
done
[[ "${BASE_DIR:-${HOME}/home-services}" == /* && "${BASE_DIR:-${HOME}/home-services}" != "/" && "${BASE_DIR:-}" != *[[:space:]]* ]] || fail "BASE_DIR musi byc bezpieczna sciezka absolutna bez spacji."
[[ "$MEDIA_MOUNT_DIR" == /* && "$MEDIA_MOUNT_DIR" != "/" && "$MEDIA_MOUNT_DIR" != *[[:space:]]* ]] || fail "MEDIA_MOUNT_DIR musi byc sciezka absolutna bez spacji."

validate_ip() {
    local ip=$1 octet
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] && (( 10#$octet <= 255 )) || return 1
    done
}

ip_to_int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    printf '%u\n' "$(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d ))"
}

[[ "$PI_IP_CIDR" =~ /24$ ]] || fail "Ten deployment obsluguje obecnie wylacznie podsiec /24."
pi_ip=${PI_IP_CIDR%/*}
[[ "$PI_IP" == "$pi_ip" ]] || fail "PI_IP musi odpowiadac adresowi z PI_IP_CIDR."
[[ "$DHCP_NETMASK" == "255.255.255.0" ]] || fail "Dla /24 DHCP_NETMASK musi wynosic 255.255.255.0."
[[ "$DHCP_LEASE_TIME" =~ ^[1-9][0-9]*[mhdw]$ ]] || fail "DHCP_LEASE_TIME musi miec format np. 24h albo 7d."
for ip in "$pi_ip" "$ROUTER_IP" "$DHCP_START" "$DHCP_END" "$UPSTREAM_DNS_1" "$UPSTREAM_DNS_2"; do
    validate_ip "$ip" || fail "Niepoprawny IPv4: ${ip}"
    [[ "${ip%.*}" == "${pi_ip%.*}" || "$ip" == "$UPSTREAM_DNS_1" || "$ip" == "$UPSTREAM_DNS_2" ]] || fail "${ip} jest poza podsiecia ${pi_ip%.*}.0/24"
done
(( $(ip_to_int "$DHCP_START") <= $(ip_to_int "$DHCP_END") )) || fail "Poczatek puli DHCP jest za koncem."
for protected in "$pi_ip" "$ROUTER_IP"; do
    value=$(ip_to_int "$protected")
    (( value < $(ip_to_int "$DHCP_START") || value > $(ip_to_int "$DHCP_END") )) || fail "${protected} nie moze nalezec do dynamicznej puli DHCP."
done

[[ ${#PIHOLE_PASSWORD} -ge 12 && "$PIHOLE_PASSWORD" != "admin" && "$PIHOLE_PASSWORD" != REPLACE_* ]] || fail "PIHOLE_PASSWORD musi miec min. 12 znakow i nie moze byc wartoscia przykladowa."
[[ "$GRAFANA_ADMIN_PASSWORD" == "admin" || ( ${#GRAFANA_ADMIN_PASSWORD} -ge 12 && "$GRAFANA_ADMIN_PASSWORD" != REPLACE_* ) ]] || fail "GRAFANA_ADMIN_PASSWORD musi byc testowym 'admin' albo miec min. 12 znakow i nie moze byc wartoscia przykladowa."
[[ -z "${TAILSCALE_AUTHKEY:-}" || "$TAILSCALE_AUTHKEY" != *REPLACE_ME* ]] || fail "Uzupelnij TAILSCALE_AUTHKEY albo zostaw pusty dla istniejacego stanu/recznego logowania."
[[ "${JELLYFIN_HTTP_PORT:-8096}" == "8096" && "${JELLYFIN_HTTPS_PORT:-8920}" == "8920" ]] || fail "Przy network_mode=host Jellyfin wymaga portow 8096 i 8920."
[[ "${GRAFANA_PORT:-3000}" =~ ^[0-9]+$ ]] && (( GRAFANA_PORT >= 1 && GRAFANA_PORT <= 65535 )) || fail "Niepoprawny GRAFANA_PORT."

declare -A seen_mac=() seen_ip=() seen_name=()
for entry in "$DHCP_HOST_1" "$DHCP_HOST_2" "$DHCP_HOST_3"; do
    IFS=, read -r mac ip hostname lease extra <<< "$entry"
    [[ "$mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || fail "Niepoprawny MAC: ${mac}"
    validate_ip "$ip" || fail "Niepoprawny adres rezerwacji: ${ip}"
    [[ "${ip%.*}" == "${pi_ip%.*}" ]] || fail "Rezerwacja ${ip} jest poza podsiecia."
    [[ -n "$hostname" && "$lease" =~ ^[1-9][0-9]*[mhdw]$ && -z "$extra" ]] || fail "Niepoprawna rezerwacja: ${entry}"
    mac_key=${mac,,}
    name_key=${hostname,,}
    [[ -z "${seen_mac[$mac_key]:-}" ]] || fail "Powtorzony MAC: ${mac}"
    [[ -z "${seen_ip[$ip]:-}" ]] || fail "Powtorzone IP: ${ip}"
    [[ -z "${seen_name[$name_key]:-}" ]] || fail "Powtorzona nazwa: ${hostname}"
    [[ "$ip" != "$pi_ip" && "$ip" != "$ROUTER_IP" ]] || fail "Rezerwacja ${ip} koliduje z hostem lub routerem."
    seen_mac[$mac_key]=1; seen_ip[$ip]=1; seen_name[$name_key]=1
done

echo "[+] Konfiguracja jest poprawna."
