#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# vLLM Cluster Shutdown Script
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Stops vLLM/Ray containers on head and all worker nodes.
# Run from head node - it will SSH to workers automatically.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration
if [ -f "${SCRIPT_DIR}/config.local.env" ]; then
  source "${SCRIPT_DIR}/config.local.env"
elif [ -f "${SCRIPT_DIR}/config.env" ]; then
  source "${SCRIPT_DIR}/config.env"
fi

HEAD_CONTAINER_NAME="${HEAD_CONTAINER_NAME:-ray-head}"
WORKER_CONTAINER_NAME="${WORKER_CONTAINER_NAME:-ray-worker}"
WORKER_IPS="${WORKER_IPS:-${WORKER_HOST:-}}"
WORKER_USER="${WORKER_USER:-$(whoami)}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Helper Functions
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

stop_local_container() {
  local name="$1"
  if docker ps -a --format '{{.Names}}' | grep -qx "${name}"; then
    log "  Stopping ${name}..."
    docker stop "${name}" >/dev/null 2>&1 || true
    docker rm -f "${name}" >/dev/null 2>&1 || true
    log "  ${name} stopped"
    return 0
  else
    return 1
  fi
}

stop_remote_containers() {
  local host="$1"
  local user="$2"

  log "  Stopping containers on ${host}..."

  # Stop ray-worker container
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${user}@${host}" "
    if docker ps -a --format '{{.Names}}' | grep -q '${WORKER_CONTAINER_NAME}'; then
      docker stop ${WORKER_CONTAINER_NAME} >/dev/null 2>&1 || true
      docker rm -f ${WORKER_CONTAINER_NAME} >/dev/null 2>&1 || true
      echo '  ${WORKER_CONTAINER_NAME} stopped'
    else
      echo '  No ${WORKER_CONTAINER_NAME} container found'
    fi
  " 2>/dev/null || log "  Warning: Could not connect to ${host}"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Parse Arguments
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

LOCAL_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --local-only)
      LOCAL_ONLY=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --local-only    Only stop local containers (skip workers)"
      echo "  -h, --help      Show this help"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Main
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Stopping vLLM Cluster"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

STOPPED_ANY=false

# Stop worker containers first (if not local-only)
if [ "${LOCAL_ONLY}" != "true" ] && [ -n "${WORKER_IPS}" ]; then
  log "Stopping worker containers..."

  for WORKER_IP in ${WORKER_IPS}; do
    stop_remote_containers "${WORKER_IP}" "${WORKER_USER}"
    STOPPED_ANY=true
  done
else
  if [ "${LOCAL_ONLY}" = "true" ]; then
    log "Skipping workers (--local-only)"
  else
    log "No worker IPs configured"
  fi
fi

# Stop head container
log "Stopping head container..."
if stop_local_container "${HEAD_CONTAINER_NAME}"; then
  STOPPED_ANY=true
else
  log "  No ${HEAD_CONTAINER_NAME} container found"
fi

# Also check for any other ray containers
for container in $(docker ps -a --format '{{.Names}}' | grep -E '^ray-' 2>/dev/null || true); do
  if [ "${container}" != "${HEAD_CONTAINER_NAME}" ]; then
    log "  Found additional container: ${container}"
    stop_local_container "${container}" && STOPPED_ANY=true
  fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "${STOPPED_ANY}" = "true" ]; then
  echo " Cluster stopped"
else
  echo " No containers were running"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
