#!/usr/bin/env bash
# rustdesk_port_test.sh
# Checks if RustDesk ports are reachable from outside

SERVER="$1"
PORTS=(21115 21116 21117 21118 21119)

echo "Testing connectivity to RustDesk server: $SERVER"

for p in "${PORTS[@]}"; do
    echo -n "Port $p TCP: "
    timeout 3 bash -c "</dev/tcp/$SERVER/$p" && echo "OPEN" || echo "CLOSED"
    echo -n "Port $p UDP: "
    timeout 3 bash -c "echo >/dev/udp/$SERVER/$p" && echo "OPEN (may be filtered)" || echo "CLOSED or filtered"
done
