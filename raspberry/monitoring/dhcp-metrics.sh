#!/usr/bin/env bash

set -Eeuo pipefail

LEASE_FILE=${1:?Podaj plik dzierzaw}
OUTPUT_FILE=${2:?Podaj plik wyjsciowy}
DHCP_START=${DHCP_START:?Brak DHCP_START}
DHCP_END=${DHCP_END:?Brak DHCP_END}

ip_to_int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    echo $(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d ))
}

pool_size=$(( $(ip_to_int "$DHCP_END") - $(ip_to_int "$DHCP_START") + 1 ))
now=$(date +%s)
active=0
if [[ -r "$LEASE_FILE" ]]; then
    active=$(awk -v now="$now" '$1 == 0 || $1 > now { count++ } END { print count + 0 }' "$LEASE_FILE")
fi

tmp="${OUTPUT_FILE}.tmp"
mkdir -p "$(dirname -- "$OUTPUT_FILE")"
cat > "$tmp" <<EOF
# HELP home_dhcp_active_leases Number of active IPv4 DHCP leases.
# TYPE home_dhcp_active_leases gauge
home_dhcp_active_leases ${active}
# HELP home_dhcp_pool_size Number of addresses in the dynamic DHCP pool.
# TYPE home_dhcp_pool_size gauge
home_dhcp_pool_size ${pool_size}
# HELP home_dhcp_pool_utilization_ratio Fraction of the dynamic DHCP pool in use.
# TYPE home_dhcp_pool_utilization_ratio gauge
home_dhcp_pool_utilization_ratio $(awk -v active="$active" -v size="$pool_size" 'BEGIN { if (size > 0) printf "%.6f", active / size; else print 0 }')
EOF
mv "$tmp" "$OUTPUT_FILE"
