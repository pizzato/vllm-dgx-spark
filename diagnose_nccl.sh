#!/usr/bin/env bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# NCCL/InfiniBand Diagnostic Script for DGX Spark
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# This script verifies that NCCL is properly configured to use InfiniBand/RoCE
# instead of falling back to standard Ethernet. Using IB/RoCE can provide
# 30-40% better performance for tensor parallel workloads.
#
# Usage:
#   ./diagnose_nccl.sh              # Check host system
#   ./diagnose_nccl.sh --container  # Check inside ray-head container
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Container name
CONTAINER="${CONTAINER:-ray-head}"
CHECK_CONTAINER=false

# Parse arguments
if [[ "${1:-}" == "--container" ]]; then
  CHECK_CONTAINER=true
fi

print_header() {
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_check() {
  echo -e "${CYAN}▶${NC} $1"
}

print_ok() {
  echo -e "  ${GREEN}✓${NC} $1"
}

print_warn() {
  echo -e "  ${YELLOW}⚠${NC} $1"
}

print_fail() {
  echo -e "  ${RED}✗${NC} $1"
}

print_info() {
  echo -e "  ${BLUE}ℹ${NC} $1"
}

# Run command either on host or in container
run_cmd() {
  if [ "$CHECK_CONTAINER" = true ]; then
    docker exec "$CONTAINER" bash -c "$1" 2>/dev/null
  else
    eval "$1" 2>/dev/null
  fi
}

# Check if command exists
has_cmd() {
  if [ "$CHECK_CONTAINER" = true ]; then
    docker exec "$CONTAINER" bash -c "command -v $1" >/dev/null 2>&1
  else
    command -v "$1" >/dev/null 2>&1
  fi
}

ISSUES_FOUND=0
WARNINGS_FOUND=0

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print_header "NCCL/InfiniBand Diagnostic Report"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ "$CHECK_CONTAINER" = true ]; then
  echo -e "  Checking inside container: ${CYAN}${CONTAINER}${NC}"
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    print_fail "Container '$CONTAINER' is not running"
    exit 1
  fi
else
  echo -e "  Checking host system"
fi
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print_check "1. InfiniBand/RoCE Device Detection"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Check for ibdev2netdev first, then fall back to ibstat
if has_cmd ibdev2netdev; then
  print_ok "ibdev2netdev command available"

  IB_DEVICES=$(run_cmd "ibdev2netdev 2>/dev/null" || echo "")
  if [ -n "$IB_DEVICES" ]; then
    print_ok "InfiniBand/RoCE devices found:"
    echo "$IB_DEVICES" | while read -r line; do
      if echo "$line" | grep -q "(Up)"; then
        echo -e "      ${GREEN}$line${NC}"
      else
        echo -e "      ${YELLOW}$line${NC}"
      fi
    done

    # Count active devices
    ACTIVE_COUNT=$(echo "$IB_DEVICES" | grep -c "(Up)" || echo "0")
    if [ "$ACTIVE_COUNT" -eq 0 ]; then
      print_fail "No active (Up) IB/RoCE devices found!"
      ISSUES_FOUND=$((ISSUES_FOUND + 1))
    else
      print_ok "$ACTIVE_COUNT active IB/RoCE device(s)"
    fi
  else
    print_fail "No IB/RoCE devices detected"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
  fi
elif [ -x /usr/sbin/ibstat ] || has_cmd ibstat; then
  # Fall back to ibstat (part of infiniband-diags, usually in /usr/sbin)
  print_ok "Using ibstat for IB detection"

  IBSTAT_PATH="/usr/sbin/ibstat"
  if [ "$CHECK_CONTAINER" = true ]; then
    IB_STAT=$(docker exec "$CONTAINER" $IBSTAT_PATH 2>/dev/null || echo "")
  else
    IB_STAT=$($IBSTAT_PATH 2>/dev/null || echo "")
  fi

  if [ -n "$IB_STAT" ]; then
    # Parse ibstat output for active devices
    ACTIVE_PORTS=$(echo "$IB_STAT" | grep -B5 "State: Active" | grep "CA '" | sed "s/.*CA '\\([^']*\\)'.*/\\1/" || echo "")
    ACTIVE_COUNT=$(echo "$IB_STAT" | grep -c "State: Active" || echo "0")

    if [ "$ACTIVE_COUNT" -gt 0 ]; then
      print_ok "$ACTIVE_COUNT active IB/RoCE port(s) found:"
      echo "$IB_STAT" | grep -E "^CA '|State:|Rate:" | head -20 | while read -r line; do
        if echo "$line" | grep -q "Active"; then
          echo -e "      ${GREEN}$line${NC}"
        elif echo "$line" | grep -q "CA '"; then
          echo -e "      ${CYAN}$line${NC}"
        else
          echo -e "      $line"
        fi
      done
    else
      print_warn "No active IB/RoCE ports found"
      WARNINGS_FOUND=$((WARNINGS_FOUND + 1))
    fi
  else
    print_fail "ibstat returned no output"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
  fi
else
  print_warn "Neither ibdev2netdev nor ibstat found"
  print_info "Install with: apt-get install -y infiniband-diags rdma-core"
  WARNINGS_FOUND=$((WARNINGS_FOUND + 1))
fi

echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print_check "2. RDMA/Verbs Libraries"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Check for libibverbs
LIBIBVERBS=$(run_cmd "ldconfig -p 2>/dev/null | grep libibverbs" || echo "")
if [ -n "$LIBIBVERBS" ]; then
  print_ok "libibverbs found"
else
  print_fail "libibverbs NOT found - NCCL cannot use RDMA!"
  print_info "Install with: apt-get install -y libibverbs1 libibverbs-dev"
  ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

# Check for librdmacm
LIBRDMACM=$(run_cmd "ldconfig -p 2>/dev/null | grep librdmacm" || echo "")
if [ -n "$LIBRDMACM" ]; then
  print_ok "librdmacm found"
else
  print_fail "librdmacm NOT found - NCCL cannot use RDMA!"
  print_info "Install with: apt-get install -y librdmacm1 librdmacm-dev"
  ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

# Check for ibverbs providers (mlx5, rxe, etc.)
PROVIDERS=$(run_cmd "ls /usr/lib/*/libibverbs/*.so 2>/dev/null || ls /usr/lib/libibverbs/*.so 2>/dev/null" || echo "")
if [ -n "$PROVIDERS" ]; then
  print_ok "ibverbs providers found:"
  echo "$PROVIDERS" | head -5 | while read -r p; do
    echo -e "      $(basename "$p")"
  done
else
  print_warn "No ibverbs provider libraries found"
  WARNINGS_FOUND=$((WARNINGS_FOUND + 1))
fi

echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print_check "3. NCCL Configuration"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Check NCCL environment variables
check_nccl_env() {
  local var_name="$1"
  local expected="$2"
  local value=$(run_cmd "echo \${$var_name:-}" || echo "")

  if [ -n "$value" ]; then
    if [ -n "$expected" ] && [ "$value" != "$expected" ]; then
      print_warn "$var_name=$value (expected: $expected)"
      WARNINGS_FOUND=$((WARNINGS_FOUND + 1))
    else
      print_ok "$var_name=$value"
    fi
  else
    if [ -n "$expected" ]; then
      print_warn "$var_name not set (recommended: $expected)"
      WARNINGS_FOUND=$((WARNINGS_FOUND + 1))
    else
      print_info "$var_name not set"
    fi
  fi
}

check_nccl_env "NCCL_IB_DISABLE" "0"
check_nccl_env "NCCL_IB_HCA" ""
check_nccl_env "NCCL_SOCKET_IFNAME" ""
check_nccl_env "NCCL_NET_GDR_LEVEL" ""
check_nccl_env "NCCL_DEBUG" ""

echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print_check "4. Network Interface Configuration"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Get IB interface from ibdev2netdev
if has_cmd ibdev2netdev; then
  IB_IFACE=$(run_cmd "ibdev2netdev 2>/dev/null | grep '(Up)' | head -1 | awk '{print \$5}' | tr -d '()'" || echo "")

  if [ -n "$IB_IFACE" ]; then
    print_ok "Primary IB/RoCE interface: $IB_IFACE"

    # Get IP on that interface
    IB_IP=$(run_cmd "ip -o addr show $IB_IFACE 2>/dev/null | grep 'inet ' | awk '{print \$4}' | cut -d'/' -f1 | head -1" || echo "")
    if [ -n "$IB_IP" ]; then
      print_ok "IP address on $IB_IFACE: $IB_IP"
    else
      print_fail "No IP address configured on $IB_IFACE"
      ISSUES_FOUND=$((ISSUES_FOUND + 1))
    fi

    # Check link speed
    SPEED=$(run_cmd "cat /sys/class/net/$IB_IFACE/speed 2>/dev/null" || echo "unknown")
    if [ "$SPEED" != "unknown" ]; then
      if [ "$SPEED" -ge 100000 ]; then
        print_ok "Link speed: ${SPEED} Mbps ($(( SPEED / 1000 )) Gbps)"
      else
        print_warn "Link speed: ${SPEED} Mbps - expected 100Gbps+ for RoCE"
        WARNINGS_FOUND=$((WARNINGS_FOUND + 1))
      fi
    fi
  else
    print_warn "Could not determine primary IB/RoCE interface"
    WARNINGS_FOUND=$((WARNINGS_FOUND + 1))
  fi
fi

echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print_check "5. NCCL Network Selection Test"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Check if NCCL can find IB devices
if [ "$CHECK_CONTAINER" = true ]; then
  print_info "Running NCCL network detection inside container..."

  NCCL_TEST=$(docker exec "$CONTAINER" bash -c '
    export NCCL_DEBUG=INFO
    export NCCL_DEBUG_SUBSYS=INIT,NET
    python3 -c "
import torch
import torch.distributed as dist
import os
os.environ[\"MASTER_ADDR\"] = \"127.0.0.1\"
os.environ[\"MASTER_PORT\"] = \"29500\"
os.environ[\"RANK\"] = \"0\"
os.environ[\"WORLD_SIZE\"] = \"1\"
if torch.cuda.is_available():
    torch.cuda.set_device(0)
    # Just initialize to trigger NCCL logging
    t = torch.zeros(1).cuda()
    print(\"NCCL_TEST_OK\")
" 2>&1 | head -100' 2>/dev/null || echo "NCCL_TEST_FAILED")

  if echo "$NCCL_TEST" | grep -q "NCCL_TEST_OK"; then
    # Check what network NCCL selected
    if echo "$NCCL_TEST" | grep -qi "ib\|infiniband\|rdma"; then
      print_ok "NCCL detected InfiniBand/RDMA support"
      echo "$NCCL_TEST" | grep -i "ib\|infiniband\|rdma\|NET" | head -5 | while read -r line; do
        echo -e "      ${GREEN}$line${NC}"
      done
    elif echo "$NCCL_TEST" | grep -qi "socket"; then
      print_warn "NCCL is using Socket transport (Ethernet fallback)"
      print_info "This means NCCL cannot use RDMA - check IB libraries"
      echo "$NCCL_TEST" | grep -i "socket\|NET" | head -5 | while read -r line; do
        echo -e "      ${YELLOW}$line${NC}"
      done
      WARNINGS_FOUND=$((WARNINGS_FOUND + 1))
    else
      print_info "Could not determine NCCL transport from logs"
    fi
  else
    print_warn "NCCL test could not be run"
    print_info "This may be normal if GPUs are in use"
  fi
else
  print_info "Run with --container to test NCCL inside the Docker container"
fi

echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print_check "6. vLLM Log Analysis (if running)"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ "$CHECK_CONTAINER" = true ]; then
  # Check vLLM log directly in container to avoid shell escaping issues with large logs
  if docker exec "$CONTAINER" test -f /var/log/vllm.log 2>/dev/null; then
    # Check for NCCL IB/RoCE usage - look for specific NET/IB or IBext patterns
    IB_LINES=$(docker exec "$CONTAINER" grep -E "NET/IB|IBext|GPU Direct RDMA" /var/log/vllm.log 2>/dev/null | head -5 || echo "")
    SOCKET_LINES=$(docker exec "$CONTAINER" grep -E "NET/Socket|Using network Socket" /var/log/vllm.log 2>/dev/null | head -3 || echo "")

    if [ -n "$IB_LINES" ]; then
      print_ok "vLLM is using InfiniBand/RoCE transport"
      echo "$IB_LINES" | while read -r line; do
        # Extract just the relevant part
        CLEAN_LINE=$(echo "$line" | sed 's/.*NCCL INFO //' | cut -c1-70)
        echo -e "      ${GREEN}${CLEAN_LINE}${NC}"
      done
    elif [ -n "$SOCKET_LINES" ]; then
      print_fail "vLLM is using Socket transport - NOT using InfiniBand!"
      print_info "This means NCCL is falling back to Ethernet (slower)"
      echo "$SOCKET_LINES" | while read -r line; do
        CLEAN_LINE=$(echo "$line" | sed 's/.*NCCL INFO //' | cut -c1-70)
        echo -e "      ${RED}${CLEAN_LINE}${NC}"
      done
      ISSUES_FOUND=$((ISSUES_FOUND + 1))
    else
      print_info "No clear NCCL transport indication in logs"
      print_info "Look for 'NET/IB' (good) or 'NET/Socket' (bad) in logs"
    fi

    # Check for actual NCCL errors (not warnings or info messages)
    # Exclude benign WARN messages like "unknown event type" which are not actionable
    NCCL_ERRORS=$(docker exec "$CONTAINER" grep -iE "NCCL (error|failed|failure)" /var/log/vllm.log 2>/dev/null | grep -vi "INFO" | tail -3 || echo "")
    if [ -n "$NCCL_ERRORS" ]; then
      print_fail "NCCL errors found in vLLM logs:"
      echo "$NCCL_ERRORS" | while read -r line; do
        echo -e "      ${RED}$(echo "$line" | cut -c1-80)${NC}"
      done
      ISSUES_FOUND=$((ISSUES_FOUND + 1))
    fi
  else
    print_info "No vLLM log found or vLLM not running"
  fi
else
  print_info "Run with --container to check vLLM logs"
fi

echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print_header "Diagnostic Summary"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ $ISSUES_FOUND -eq 0 ] && [ $WARNINGS_FOUND -eq 0 ]; then
  echo -e "${GREEN}✓ All checks passed - NCCL should be using InfiniBand/RoCE${NC}"
elif [ $ISSUES_FOUND -eq 0 ]; then
  echo -e "${YELLOW}⚠ $WARNINGS_FOUND warning(s) found - review recommendations above${NC}"
else
  echo -e "${RED}✗ $ISSUES_FOUND critical issue(s) found!${NC}"
  echo ""
  echo -e "${BOLD}Required packages for NCCL RDMA support:${NC}"
  echo ""
  echo "  # On host (Ubuntu/Debian):"
  echo "  sudo apt-get install -y \\"
  echo "    infiniband-diags \\"
  echo "    libibverbs1 \\"
  echo "    libibverbs-dev \\"
  echo "    librdmacm1 \\"
  echo "    librdmacm-dev \\"
  echo "    rdma-core \\"
  echo "    ibverbs-providers"
  echo ""
  echo "  # Inside Docker container:"
  echo "  docker exec $CONTAINER apt-get update"
  echo "  docker exec $CONTAINER apt-get install -y \\"
  echo "    infiniband-diags \\"
  echo "    libibverbs1 \\"
  echo "    librdmacm1 \\"
  echo "    rdma-core \\"
  echo "    ibverbs-providers"
fi

echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print_header "InfiniBand vs Ethernet"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "  InfiniBand/RoCE provides significant performance benefits for"
echo "  multi-node tensor parallel inference:"
echo ""
echo "  - 30-40% higher throughput vs Ethernet for tensor parallelism"
echo "  - GPU Direct RDMA enables direct GPU-to-GPU memory transfers"
echo "  - Lower latency for NCCL collective operations"
echo ""
echo "  Key indicators of proper IB configuration:"
echo "    - vLLM logs show 'NET/IB' or 'IBext' (not 'NET/Socket')"
echo "    - 'GPU Direct RDMA enabled' in NCCL output"
echo "    - ibstat shows 'State: Active' on RoCE ports"
echo ""

exit $ISSUES_FOUND
