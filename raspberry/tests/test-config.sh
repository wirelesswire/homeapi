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

echo "[+] Testy konfiguracji i metryk DHCP przeszly."
