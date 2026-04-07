#!/usr/bin/env bash
set -euo pipefail

PERSIST=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Tunes OS parameters for database benchmark client VMs.

Options:
  --persist   Write settings to /etc/sysctl.d/99-benchmark.conf
              and /etc/security/limits.conf (survives reboot)
  --help      Show this help message

Tuned parameters:
  - ulimit -n 65535
  - net.ipv4.tcp_max_syn_backlog=65535
  - net.core.somaxconn=65535
  - net.ipv4.tcp_tw_reuse=1
  - net.ipv4.ip_local_port_range=1024 65535
  - vm.swappiness=1
EOF
}

for arg in "$@"; do
  case "$arg" in
    --persist) PERSIST=1 ;;
    --help)    usage; exit 0 ;;
    *)
      echo "ERROR: Unknown argument: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: This script must be run as root (or via sudo)." >&2
  exit 1
fi

echo "=== BEFORE ==="
echo "ulimit -n (open files): $(ulimit -n)"
echo "net.ipv4.tcp_max_syn_backlog: $(sysctl -n net.ipv4.tcp_max_syn_backlog)"
echo "net.core.somaxconn:           $(sysctl -n net.core.somaxconn)"
echo "net.ipv4.tcp_tw_reuse:        $(sysctl -n net.ipv4.tcp_tw_reuse)"
echo "net.ipv4.ip_local_port_range: $(sysctl -n net.ipv4.ip_local_port_range)"
echo "vm.swappiness:                $(sysctl -n vm.swappiness)"
echo ""

echo "=== APPLYING TUNING ==="

ulimit -n 65535
echo "  ulimit -n set to 65535"

sysctl -w net.ipv4.tcp_max_syn_backlog=65535
sysctl -w net.core.somaxconn=65535
sysctl -w net.ipv4.tcp_tw_reuse=1
sysctl -w net.ipv4.ip_local_port_range="1024 65535"
sysctl -w vm.swappiness=1

echo ""

echo "=== AFTER ==="
echo "ulimit -n (open files): $(ulimit -n)"
echo "net.ipv4.tcp_max_syn_backlog: $(sysctl -n net.ipv4.tcp_max_syn_backlog)"
echo "net.core.somaxconn:           $(sysctl -n net.core.somaxconn)"
echo "net.ipv4.tcp_tw_reuse:        $(sysctl -n net.ipv4.tcp_tw_reuse)"
echo "net.ipv4.ip_local_port_range: $(sysctl -n net.ipv4.ip_local_port_range)"
echo "vm.swappiness:                $(sysctl -n vm.swappiness)"
echo ""

if [[ "$PERSIST" -eq 1 ]]; then
  echo "=== PERSISTING SETTINGS ==="

  SYSCTL_CONF="/etc/sysctl.d/99-benchmark.conf"
  cat > "$SYSCTL_CONF" <<'SYSCTL'
# Benchmark client tuning - managed by os_tuning.sh
net.ipv4.tcp_max_syn_backlog = 65535
net.core.somaxconn = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
vm.swappiness = 1
SYSCTL
  echo "  Written: $SYSCTL_CONF"

  LIMITS_CONF="/etc/security/limits.conf"
  if grep -q "# benchmark-client-tuning" "$LIMITS_CONF" 2>/dev/null; then
    sed -i '/# benchmark-client-tuning/,/# end-benchmark-client-tuning/d' "$LIMITS_CONF"
  fi
  cat >> "$LIMITS_CONF" <<'LIMITS'
# benchmark-client-tuning
*    soft nofile 65535
*    hard nofile 65535
root soft nofile 65535
root hard nofile 65535
# end-benchmark-client-tuning
LIMITS
  echo "  Updated: $LIMITS_CONF"
  echo ""
  echo "Settings will persist after reboot."
fi

echo "=== DONE ==="
