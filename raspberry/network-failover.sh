#!/usr/bin/env bash

set -Eeuo pipefail

MODE=${1:-once}
ENV_FILE=${2:-/home/user/home-services/.env}
STATE_FILE=/run/home-services-network-interface
INSTALL_MARKER=/run/home-services-installing

[[ -r "$ENV_FILE" ]] || { echo "Brakuje ${ENV_FILE}" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

ETH_INTERFACE=${ETH_INTERFACE:-eth0}
WLAN_INTERFACE=${WLAN_INTERFACE:-wlan0}

exists() { [[ -e "/sys/class/net/$1" ]]; }
carrier() { [[ -r "/sys/class/net/$1/carrier" ]] && [[ "$(cat "/sys/class/net/$1/carrier" 2>/dev/null)" == 1 ]]; }

current_route_interface() {
    ip -4 route show default | awk '{ print $5; exit }'
}

configure_dns() {
    local target=$1 iface
    command -v resolvectl >/dev/null 2>&1 || return
    for iface in "$ETH_INTERFACE" "$WLAN_INTERFACE"; do
        exists "$iface" && resolvectl revert "$iface" 2>/dev/null || true
    done
    resolvectl dns "$target" "$UPSTREAM_DNS_1" "$UPSTREAM_DNS_2" || true
    resolvectl domain "$target" '~.' || true
}

choose_interface() {
    local current
    if [[ -e "$INSTALL_MARKER" ]]; then
        current="$(current_route_interface)"
        if [[ -n "$current" ]] && exists "$current" && carrier "$current"; then
            printf '%s\n' "$current"
            return
        fi
    fi
    if exists "$ETH_INTERFACE" && carrier "$ETH_INTERFACE"; then
        printf '%s\n' "$ETH_INTERFACE"
    elif exists "$WLAN_INTERFACE" && carrier "$WLAN_INTERFACE"; then
        printf '%s\n' "$WLAN_INTERFACE"
    else
        return 1
    fi
}

configure_interface() {
    local target=$1 iface current
    current="$(cat "$STATE_FILE" 2>/dev/null || true)"

    if ip -4 address show dev "$target" | grep -Fq "inet ${PI_IP_CIDR}" && \
       ip -4 route show default | grep -Fq "via ${ROUTER_IP} dev ${target}"; then
        configure_dns "$target"
        printf '%s\n' "$target" > "$STATE_FILE"
        return
    fi

    for iface in "$ETH_INTERFACE" "$WLAN_INTERFACE"; do
        exists "$iface" || continue
        ip -4 address del "$PI_IP_CIDR" dev "$iface" 2>/dev/null || true
        ip -4 route del default dev "$iface" 2>/dev/null || true
    done

    ip link set "$target" up
    ip -4 address add "$PI_IP_CIDR" dev "$target"
    ip -4 route replace default via "$ROUTER_IP" dev "$target" metric 100

    configure_dns "$target"

    if command -v arping >/dev/null 2>&1; then
        arping -q -U -c 3 -I "$target" "${PI_IP_CIDR%/*}" 2>/dev/null || true
    fi

    printf '%s\n' "$target" > "$STATE_FILE"
    echo "[home-services-network] ${current:-none} -> ${target} (${PI_IP_CIDR})"
}

run_once() {
    local attempt target
    for attempt in $(seq 1 90); do
        if target="$(choose_interface)"; then
            configure_interface "$target"
            return
        fi
        sleep 1
    done
    echo "Nie znaleziono aktywnego Ethernetu ani Wi-Fi." >&2
    return 1
}

case "$MODE" in
    once) run_once ;;
    monitor)
        run_once
        while sleep 3; do
            target="$(choose_interface || true)"
            [[ -n "$target" ]] || continue
            [[ "$(cat "$STATE_FILE" 2>/dev/null || true)" == "$target" ]] || configure_interface "$target"
        done
        ;;
    *) echo "Uzycie: $0 {once|monitor} [env-file]" >&2; exit 2 ;;
esac
