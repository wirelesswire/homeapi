#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="${ROOT}/tests/.env.valid"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

bash "${ROOT}/validate-config.sh" "$FIXTURE"

sed 's#PIHOLE_PASSWORD=.*#PIHOLE_PASSWORD=REPLACE_WITH_A_LONG_RANDOM_PASSWORD#; s#GRAFANA_ADMIN_PASSWORD=.*#GRAFANA_ADMIN_PASSWORD=REPLACE_WITH_A_DIFFERENT_LONG_PASSWORD#' "$FIXTURE" > "${tmp_dir}/placeholder.env"
if bash "${ROOT}/validate-config.sh" "${tmp_dir}/placeholder.env" >/dev/null 2>&1; then
    echo "Walidator zaakceptowal przykladowe hasla." >&2
    exit 1
fi

sed 's#DHCP_HOST_2=.*#DHCP_HOST_2=10:5B:AD:A1:55:A9,192.168.1.16,duplicate,24h#' "$FIXTURE" > "${tmp_dir}/duplicate.env"
if bash "${ROOT}/validate-config.sh" "${tmp_dir}/duplicate.env" >/dev/null 2>&1; then
    echo "Walidator zaakceptowal powtorzony MAC." >&2
    exit 1
fi

now="$(date +%s)"
printf '%s aa:bb:cc:dd:ee:01 192.168.1.20 phone *\n%s aa:bb:cc:dd:ee:02 192.168.1.21 tablet *\n' \
    "$((now + 3600))" "$((now - 10))" > "${tmp_dir}/leases"
DHCP_START=192.168.1.20 DHCP_END=192.168.1.250 \
    bash "${ROOT}/monitoring/dhcp-metrics.sh" "${tmp_dir}/leases" "${tmp_dir}/dhcp.prom"
grep -q '^home_dhcp_active_leases 1$' "${tmp_dir}/dhcp.prom"
grep -q '^home_dhcp_pool_size 231$' "${tmp_dir}/dhcp.prom"

grep -Fq 'Skonfigurowano automatyczny failover' "${ROOT}/setup-home-services.sh"
grep -Fq 'if exists "$ETH_INTERFACE" && carrier "$ETH_INTERFACE"' "${ROOT}/network-failover.sh"
grep -Fq '[[ ! -d "$MEDIA_MOUNT_DIR" ]]' "${ROOT}/setup-home-services.sh"
grep -Fq 'image: ghcr.io/google/cadvisor:v0.60.5' "${ROOT}/compose.yaml"
grep -Fq 'http://127.0.0.1:8081/healthz' "${ROOT}/compose.yaml"
grep -Fq 'TimeoutStartSec=0' "${ROOT}/setup-home-services.sh"
grep -Fq 'sudo docker compose --env-file .env -f compose.yaml pull' "${ROOT}/setup-home-services.sh"
grep -Fq 'INSTALL_MARKER_CREATED=false' "${ROOT}/setup-home-services.sh"
grep -Fq 'trap cleanup_install_marker EXIT' "${ROOT}/setup-home-services.sh"
scrub_function="$(sed -n '/^scrub_tailscale_authkey()/,/^}/p' "${ROOT}/setup-home-services.sh")"
eval "$scrub_function"
export TAILSCALE_AUTHKEY=''
scrub_tailscale_authkey

link_function="$(sed -n '/^write_networkd_link_config()/,/^}/p' "${ROOT}/setup-home-services.sh")"
eval "$link_function"
write_networkd_link_config home_services_missing_interface

dns_functions="$(sed -n '/^exists()/,/^}/p; /^configure_dns()/,/^}/p' "${ROOT}/network-failover.sh")"
eval "$dns_functions"
PATH=/nonexistent configure_dns wlan0

grep -Fq "old_reservation='50:91:E2:21:BA:17,192.168.1.12,stacjonarny,24h'" "${ROOT}/setup-home-services.sh"
grep -Fq "new_reservation='50:91:E3:21:BA:17,192.168.1.12,stacjonarny,24h'" "${ROOT}/setup-home-services.sh"
sed 's/50:91:E3:21:BA:17/50:91:E2:21:BA:17/' "$FIXTURE" > "${tmp_dir}/migration.env"
migration_function="$(sed -n '/^migrate_known_configuration()/,/^}/p' "${ROOT}/setup-home-services.sh")"
eval "$migration_function"
fail() { echo "$*" >&2; return 1; }
ok() { :; }
SOURCE_ENV="${tmp_dir}/migration.env"
export DHCP_HOST_2='50:91:E2:21:BA:17,192.168.1.12,stacjonarny,24h'
migrate_known_configuration
grep -Fq 'DHCP_HOST_2=50:91:E3:21:BA:17,192.168.1.12,stacjonarny,24h' "$SOURCE_ENV"
if grep -Fq 'networkctl reload' "${ROOT}/setup-home-services.sh"; then
    echo "Instalator nie moze przeladowywac sieci podczas sesji SSH." >&2
    exit 1
fi
if grep -Eq 'image:[[:space:]]+\$\{[A-Z_]+_IMAGE' "${ROOT}/compose.yaml"; then
    echo "Wersje obrazow nie moga zalezec od lokalnego .env." >&2
    exit 1
fi

echo "[+] Testy konfiguracji i metryk DHCP przeszly."
