#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# DGX Spark vLLM Head Node - Production Setup Script
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Configuration
IMAGE="${IMAGE:-nvcr.io/nvidia/vllm:25.10-py3}"
NAME="${NAME:-ray-head}"
HF_CACHE="${HF_CACHE:-/raid/hf-cache}"
HF_TOKEN="${HF_TOKEN:-}"  # Set via: export HF_TOKEN=hf_xxx
RAY_VERSION="${RAY_VERSION:-2.52.0}"

# Worker node configuration (for orchestrated setup)
# Set WORKER_HOST to enable automatic worker setup from head node
WORKER_HOST="${WORKER_HOST:-192.168.7.111}"  # Default to second DGX Spark
WORKER_USER="${WORKER_USER:-$(whoami)}"
WORKER_HF_CACHE="${WORKER_HF_CACHE:-${HF_CACHE}}"  # Worker's HF cache path (same as head by default)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Model configuration
MODEL="${MODEL:-openai/gpt-oss-120b}"
TENSOR_PARALLEL="${TENSOR_PARALLEL:-2}"  # Default to 2 for distributed inference
MAX_MODEL_LEN="${MAX_MODEL_LEN:-8192}"   # Context length for Qwen2.5
GPU_MEMORY_UTIL="${GPU_MEMORY_UTIL:-0.90}"  # Can be aggressive with smaller model

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Auto-detect Network Configuration
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Uses ibdev2netdev to discover active InfiniBand/RoCE interfaces.
# The IP address on the IB/RoCE interface can be any valid IP (not limited
# to link-local addresses). We rely on ibdev2netdev output to identify the
# correct network interface for RDMA communication.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Discover primary RoCE/IB interface using ibdev2netdev
discover_ib_interface() {
  if command -v ibdev2netdev >/dev/null 2>&1; then
    # Get the first active (Up) interface from ibdev2netdev
    local active_line
    active_line=$(ibdev2netdev 2>/dev/null | awk '/\(Up\)/ {print; exit}')

    if [ -n "$active_line" ]; then
      # Extract interface name (5th field, removing parentheses)
      echo "$active_line" | awk '{print $5}' | tr -d '()'
    fi
  fi
}

# Get all active IB/RoCE HCAs (comma-separated for NCCL_IB_HCA)
discover_all_ib_hcas() {
  if command -v ibdev2netdev >/dev/null 2>&1; then
    ibdev2netdev 2>/dev/null | grep "(Up)" | awk '{print $1}' | sort | tr '\n' ',' | sed 's/,$//'
  fi
}

# Get the first IPv4 address from an interface
get_interface_ip() {
  local iface="$1"
  if [ -n "$iface" ]; then
    ip -o addr show "$iface" 2>/dev/null | grep "inet " | awk '{print $4}' | cut -d'/' -f1 | head -1
  fi
}

# Auto-detect primary IB/RoCE interface
PRIMARY_IB_IF=$(discover_ib_interface)

# Auto-detect HEAD_IP from IB interface (or use override)
if [ -z "${HEAD_IP:-}" ]; then
  if [ -n "${PRIMARY_IB_IF}" ]; then
    HEAD_IP=$(get_interface_ip "${PRIMARY_IB_IF}")
  fi
  # Final fallback if auto-detection fails
  if [ -z "${HEAD_IP:-}" ]; then
    echo "ERROR: Could not auto-detect HEAD_IP from InfiniBand/RoCE interface."
    echo ""
    echo "Please ensure:"
    echo "  1. The InfiniBand/RoCE cable is connected between nodes"
    echo "  2. Run 'ibdev2netdev' to verify IB/RoCE interfaces are Up"
    echo "  3. Check that an IP is assigned to the IB/RoCE interface"
    echo ""
    echo "Then either:"
    echo "  - Fix the interface and re-run this script, OR"
    echo "  - Set HEAD_IP manually: export HEAD_IP=<your_ib_ip>"
    exit 1
  fi
fi

# Auto-detect network interfaces from active IB/RoCE devices
if [ -z "${GLOO_IF:-}" ] || [ -z "${TP_IF:-}" ] || [ -z "${NCCL_IF:-}" ] || [ -z "${UCX_DEV:-}" ]; then
  if [ -n "${PRIMARY_IB_IF}" ]; then
    # Use primary IB interface for all NCCL/GLOO/TP/UCX communication
    GLOO_IF="${GLOO_IF:-${PRIMARY_IB_IF}}"
    TP_IF="${TP_IF:-${PRIMARY_IB_IF}}"
    NCCL_IF="${NCCL_IF:-${PRIMARY_IB_IF}}"
    UCX_DEV="${UCX_DEV:-${PRIMARY_IB_IF}}"
  else
    # Error if no IB interface detected and not manually specified
    echo "ERROR: No active InfiniBand/RoCE interface detected."
    echo "Run 'ibdev2netdev' to check interface status."
    exit 1
  fi
fi

# Auto-detect InfiniBand HCAs using ibdev2netdev (or use override)
if [ -z "${NCCL_IB_HCA:-}" ]; then
  IB_DEVICES=$(discover_all_ib_hcas)
  if [ -n "${IB_DEVICES}" ]; then
    NCCL_IB_HCA="${IB_DEVICES}"
  else
    # Fallback: use all IB devices from sysfs
    IB_DEVICES=$(ls -1 /sys/class/infiniband/ 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    NCCL_IB_HCA="${IB_DEVICES:-}"
    if [ -z "${NCCL_IB_HCA}" ]; then
      echo "ERROR: No InfiniBand HCAs detected."
      echo "Run 'ibdev2netdev' or check /sys/class/infiniband/"
      exit 1
    fi
  fi
fi

# Set OMPI_MCA for MPI-based communication (needed for some frameworks)
OMPI_MCA_IF="${NCCL_IF}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

error() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Starting DGX Spark vLLM Head Node Setup"
log "Configuration:"
log "  Image:           ${IMAGE}"
log "  Head IP:         ${HEAD_IP} (auto-detected)"
log "  Model:           ${MODEL}"
log "  Tensor Parallel: ${TENSOR_PARALLEL}"
log "  Ray Version:     ${RAY_VERSION}"
log ""
if [ -n "${WORKER_HOST}" ]; then
  log "Worker Node Configuration (orchestrated setup enabled):"
  log "  Worker Host:     ${WORKER_HOST}"
  log "  Worker User:     ${WORKER_USER}"
  log "  Worker HF Cache: ${WORKER_HF_CACHE}"
  log ""
else
  log "Worker Node Configuration:"
  log "  ⚠️  WORKER_HOST not set - manual worker setup required"
  log "     Set WORKER_HOST=<ip> to enable automatic worker orchestration"
  log ""
fi
log "Network Configuration (auto-detected from ibdev2netdev):"
log "  Primary IB IF:   ${PRIMARY_IB_IF:-<not detected>}"
log "  GLOO Interface:  ${GLOO_IF}"
log "  TP Interface:    ${TP_IF}"
log "  NCCL Interface:  ${NCCL_IF}"
log "  UCX Device:      ${UCX_DEV}"
log "  OMPI MCA IF:     ${OMPI_MCA_IF}"
log "  NCCL IB HCAs:    ${NCCL_IB_HCA}"
log ""
if [ -n "${HF_TOKEN}" ]; then
  log "  HF Auth:        ✅ Token provided"
else
  log "  HF Auth:        ⚠️  No token (gated models will fail)"
fi
log ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Calculate total steps based on whether worker orchestration is enabled
if [ -n "${WORKER_HOST}" ]; then
  TOTAL_STEPS=13
else
  TOTAL_STEPS=10
fi
STEP=0

next_step() {
  STEP=$((STEP + 1))
  echo "${STEP}/${TOTAL_STEPS}"
}

log "Step $(next_step): Pulling Docker image"
if ! docker pull "${IMAGE}"; then
  error "Failed to pull image ${IMAGE}"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step $(next_step): Cleaning old container"
if docker ps -a --format '{{.Names}}' | grep -qx "${NAME}"; then
  log "  Removing existing container: ${NAME}"
  docker rm -f "${NAME}" >/dev/null
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step $(next_step): Starting head container"

# Build environment variable args for IB/NCCL configuration
# These are passed into the container to ensure NCCL uses the IB/RoCE link
ENV_ARGS=(
  -e VLLM_HOST_IP="${HEAD_IP}"
  # IB/RoCE interface settings for NCCL communication
  -e GLOO_SOCKET_IFNAME="${GLOO_IF}"
  -e TP_SOCKET_IFNAME="${TP_IF}"
  -e NCCL_SOCKET_IFNAME="${NCCL_IF}"
  -e UCX_NET_DEVICES="${UCX_DEV}"
  -e OMPI_MCA_btl_tcp_if_include="${OMPI_MCA_IF}"
  # NCCL InfiniBand settings
  -e NCCL_IB_DISABLE=0
  -e NCCL_IB_HCA="${NCCL_IB_HCA}"
  -e NCCL_NET_GDR_LEVEL=5
  # Debug settings (can be disabled for production by setting NCCL_DEBUG=WARN)
  -e NCCL_DEBUG="${NCCL_DEBUG:-INFO}"
  -e NCCL_DEBUG_SUBSYS="${NCCL_DEBUG_SUBSYS:-INIT,NET}"
  # NVIDIA/GPU settings
  -e NVIDIA_VISIBLE_DEVICES=all
  -e NVIDIA_DRIVER_CAPABILITIES=all
  # Ray settings
  -e RAY_memory_usage_threshold=0.998
  -e RAY_GCS_SERVER_PORT=6380
  # HuggingFace cache
  -e HF_HOME=/root/.cache/huggingface
)

# Add HuggingFace token if provided
if [ -n "${HF_TOKEN}" ]; then
  ENV_ARGS+=(-e HF_TOKEN="${HF_TOKEN}")
fi

# Run container as root (required for NVIDIA/vLLM)
# HF cache is mounted to /root/.cache/huggingface
docker run -d \
  --restart unless-stopped \
  --name "${NAME}" \
  --gpus all \
  --network host \
  --shm-size=16g \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  --device=/dev/infiniband \
  -v "${HF_CACHE}:/root/.cache/huggingface" \
  "${ENV_ARGS[@]}" \
  "${IMAGE}" sleep infinity

if ! docker ps | grep -q "${NAME}"; then
  error "Container failed to start"
fi

log "  Container started successfully"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step $(next_step): Installing RDMA/InfiniBand libraries for NCCL"
log "  These libraries are required for NCCL to use InfiniBand/RoCE instead of Ethernet"
if ! docker exec "${NAME}" bash -lc "
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq \
    infiniband-diags \
    libibverbs1 \
    librdmacm1 \
    rdma-core \
    ibverbs-providers \
    >/dev/null 2>&1
"; then
  log "  ⚠️  Warning: Could not install RDMA libraries (may already be present)"
fi

# Verify RDMA libraries are available
if docker exec "${NAME}" bash -lc "ldconfig -p 2>/dev/null | grep -q libibverbs"; then
  log "  ✅ RDMA libraries installed (libibverbs, librdmacm)"
else
  log "  ⚠️  Warning: RDMA libraries may not be properly installed"
  log "     NCCL may fall back to Socket transport (slower)"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step $(next_step): Installing Ray ${RAY_VERSION}"
if ! docker exec "${NAME}" bash -lc "pip install -q -U --root-user-action=ignore 'ray==${RAY_VERSION}'"; then
  error "Failed to install Ray"
fi

# Verify Ray version
INSTALLED_RAY_VERSION=$(docker exec "${NAME}" python3 -c "import ray; print(ray.__version__)" 2>/dev/null || echo "unknown")
if [ "${INSTALLED_RAY_VERSION}" != "${RAY_VERSION}" ]; then
  error "Ray version mismatch: expected ${RAY_VERSION}, got ${INSTALLED_RAY_VERSION}"
fi

log "  Ray ${INSTALLED_RAY_VERSION} installed"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step $(next_step): Pre-downloading model weights"
log "  Model: ${MODEL}"
log "  This may take a while for large models on first download..."

# Build HF token arg if provided
HF_TOKEN_ARG=""
if [ -n "${HF_TOKEN}" ]; then
  HF_TOKEN_ARG="--token ${HF_TOKEN}"
fi

# Download model with verification
if ! docker exec "${NAME}" bash -lc "
  export HF_HOME=/root/.cache/huggingface
  echo '  Downloading model files (excluding original/* and metal/* to save space)...'
  hf download ${MODEL} ${HF_TOKEN_ARG} --exclude 'original/*' --exclude 'metal/*' 2>&1 | tail -5
"; then
  error "Failed to download model ${MODEL}"
fi

# Verify model was downloaded by checking for config.json
if ! docker exec "${NAME}" bash -lc "
  export HF_HOME=/root/.cache/huggingface
  python3 -c \"
from huggingface_hub import snapshot_download
import os
path = snapshot_download('${MODEL}', local_files_only=True)
config_path = os.path.join(path, 'config.json')
if not os.path.exists(config_path):
    raise FileNotFoundError(f'Model config not found at {config_path}')
print(f'  ✅ Model verified at: {path}')
\"
"; then
  error "Model verification failed - config.json not found"
fi

log "  Model download complete and verified"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Worker orchestration steps (only if WORKER_HOST is set)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ -n "${WORKER_HOST}" ]; then
  log "Step $(next_step): Syncing model to worker node"
  log "  Worker host: ${WORKER_USER}@${WORKER_HOST}"
  log "  Source: ${HF_CACHE}/"
  log "  Destination: ${WORKER_HF_CACHE}/"
  log ""
  log "  This may take a while for large models..."

  # Test SSH connectivity first
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${WORKER_USER}@${WORKER_HOST}" "echo 'SSH OK'" >/dev/null 2>&1; then
    error "Cannot SSH to ${WORKER_USER}@${WORKER_HOST}. Please ensure:"$'\n'"  1. SSH keys are set up (ssh-copy-id ${WORKER_USER}@${WORKER_HOST})"$'\n'"  2. The worker host is reachable"
  fi
  log "  ✅ SSH connectivity verified"

  # Ensure destination directory exists and fix permissions if needed
  ssh "${WORKER_USER}@${WORKER_HOST}" "
    mkdir -p ${WORKER_HF_CACHE}/hub
    # Fix ownership if directories exist but are owned by root (from Docker)
    if [ -d '${WORKER_HF_CACHE}' ] && [ ! -w '${WORKER_HF_CACHE}' ]; then
      echo 'Fixing permissions on ${WORKER_HF_CACHE} (requires sudo)...'
      sudo chown -R \$(id -u):\$(id -g) '${WORKER_HF_CACHE}' 2>/dev/null || true
    fi
  "

  # Convert model name to HF cache directory format (e.g., openai/gpt-oss-120b -> models--openai--gpt-oss-120b)
  MODEL_CACHE_NAME="models--$(echo "${MODEL}" | sed 's|/|--|g')"
  MODEL_CACHE_PATH="${HF_CACHE}/hub/${MODEL_CACHE_NAME}"

  if [ ! -d "${MODEL_CACHE_PATH}" ]; then
    error "Model cache not found at ${MODEL_CACHE_PATH}. Download the model first."
  fi

  log "  Syncing model: ${MODEL_CACHE_NAME}"
  log "  From: ${MODEL_CACHE_PATH}"
  log "  To:   ${WORKER_USER}@${WORKER_HOST}:${WORKER_HF_CACHE}/hub/"

  # Rsync only the specific model directory (exclude lock files)
  # Use --no-perms --no-owner --no-group to avoid permission issues with mixed ownership
  if ! rsync -a --info=progress2 --human-readable \
    --no-perms --no-owner --no-group \
    --exclude='.locks' \
    --exclude='*.lock' \
    "${MODEL_CACHE_PATH}" \
    "${WORKER_USER}@${WORKER_HOST}:${WORKER_HF_CACHE}/hub/"; then
    error "Failed to rsync model to worker node"
  fi
  log "  ✅ Model synced to worker"

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  log "Step $(next_step): Copying worker script to worker node"
  WORKER_SCRIPT="${SCRIPT_DIR}/start_worker_vllm.sh"

  if [ ! -f "${WORKER_SCRIPT}" ]; then
    error "Worker script not found at ${WORKER_SCRIPT}"
  fi

  # Copy the worker script to the worker's home directory
  if ! scp "${WORKER_SCRIPT}" "${WORKER_USER}@${WORKER_HOST}:~/start_worker_vllm.sh"; then
    error "Failed to copy worker script to ${WORKER_HOST}"
  fi
  log "  ✅ Worker script copied to ${WORKER_USER}@${WORKER_HOST}:~/start_worker_vllm.sh"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step $(next_step): Starting Ray head"
docker exec "${NAME}" bash -lc "
  ray stop --force 2>/dev/null || true
  ray start --head \
    --node-ip-address=${HEAD_IP} \
    --port=6380 \
    --dashboard-host=0.0.0.0 \
    --dashboard-port=8265
" >/dev/null

log "  Ray head started, waiting for readiness..."

# Wait for Ray to become ready
for i in {1..30}; do
  if docker exec "${NAME}" bash -lc "ray status --address='127.0.0.1:6380' >/dev/null 2>&1"; then
    log "  ✅ Ray head is ready (${i}s)"
    break
  fi
  if [ $i -eq 30 ]; then
    error "Ray head failed to become ready after 30 seconds"
  fi
  sleep 1
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ -n "${WORKER_HOST}" ]; then
  # Orchestrated mode: Start worker via SSH
  log "Step $(next_step): Starting worker node via SSH"
  log "  Starting worker script on ${WORKER_USER}@${WORKER_HOST}..."
  log ""

  # Build environment variables to pass to worker
  # Worker needs HEAD_IP, MODEL, HF_TOKEN, and HF_CACHE
  WORKER_ENV="HEAD_IP=${HEAD_IP} MODEL=${MODEL} HF_CACHE=${WORKER_HF_CACHE} RAY_VERSION=${RAY_VERSION} SKIP_MODEL_DOWNLOAD=1"
  if [ -n "${HF_TOKEN}" ]; then
    WORKER_ENV="${WORKER_ENV} HF_TOKEN=${HF_TOKEN}"
  fi

  # Start the worker script via SSH (run in background)
  # Use ssh -f with nohup to properly detach the process
  # The sleep 1 at the end ensures SSH doesn't exit before nohup takes over
  ssh -f "${WORKER_USER}@${WORKER_HOST}" "nohup bash -c '${WORKER_ENV} bash ~/start_worker_vllm.sh > ~/worker_setup.log 2>&1' </dev/null >/dev/null 2>&1 &"

  # Give SSH a moment to start the remote process
  sleep 2

  log "  Worker script started in background on ${WORKER_HOST}"
  log "  Logs available at: ${WORKER_USER}@${WORKER_HOST}:~/worker_setup.log"
  log ""

  # Wait for worker to join the cluster (check for 2+ nodes)
  log "  Waiting for worker to join Ray cluster..."
  WORKER_JOINED=false
  for i in {1..120}; do
    NODE_COUNT=$(docker exec "${NAME}" bash -lc "ray status --address=127.0.0.1:6380 2>/dev/null | grep -E '^ [0-9]+ node_' | wc -l" 2>/dev/null || echo "0")
    CURRENT_GPUS=$(docker exec "${NAME}" bash -lc "ray status --address=127.0.0.1:6380 2>/dev/null | grep 'GPU:' | awk -F'/' '{print \$2}' | awk '{print \$1}'" 2>/dev/null || echo "1")

    if [ "${NODE_COUNT}" -ge 2 ]; then
      echo ""
      log "  ✅ Worker joined cluster (${i}s) - ${NODE_COUNT} nodes, ${CURRENT_GPUS} GPUs"
      WORKER_JOINED=true
      break
    fi

    # Show spinner
    SPINNER="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    SPIN_CHAR="${SPINNER:$((i % 10)):1}"
    printf "\r  %s Waiting for worker... [%ds elapsed, %s nodes]  " "${SPIN_CHAR}" "${i}" "${NODE_COUNT}"

    sleep 1
  done

  if [ "${WORKER_JOINED}" != "true" ]; then
    echo ""
    log "  ⚠️  Worker did not join cluster within 120s"
    log "     Check worker logs: ssh ${WORKER_USER}@${WORKER_HOST} 'cat ~/worker_setup.log'"
    log ""
    log "  Proceeding anyway - vLLM may fail if insufficient GPUs"
  fi

else
  # Manual mode: Wait for user to start workers
  log "Step $(next_step): Waiting for worker nodes"
  log ""
  log "  ⚠️  IMPORTANT: Before proceeding, ensure all worker nodes have:"
  log "     1. Downloaded the model: export MODEL=${MODEL} && bash start_worker_vllm.sh"
  log "     2. Joined the Ray cluster"
  log ""
  log "  Checking Ray cluster status..."

  # Show current cluster status
  docker exec "${NAME}" bash -lc "ray status --address=127.0.0.1:6380 2>/dev/null | head -15" || true

  CURRENT_NODES=$(docker exec "${NAME}" bash -lc "ray status --address=127.0.0.1:6380 2>/dev/null | grep -E '^ [0-9]+ node' | awk '{print \$1}'" 2>/dev/null || echo "1")
  CURRENT_GPUS=$(docker exec "${NAME}" bash -lc "ray status --address=127.0.0.1:6380 2>/dev/null | grep 'GPU:' | awk -F'/' '{print \$2}' | awk '{print \$1}'" 2>/dev/null || echo "1")

  log ""
  log "  Current cluster: ${CURRENT_NODES} node(s), ${CURRENT_GPUS} GPU(s)"

  if [ "${TENSOR_PARALLEL}" -gt "${CURRENT_GPUS:-1}" ]; then
    log ""
    log "  ⚠️  Warning: tensor-parallel-size (${TENSOR_PARALLEL}) > available GPUs (${CURRENT_GPUS})"
    log "     Waiting 30 seconds for worker nodes to join..."
    log "     (Press Ctrl+C to abort and add workers manually)"

    for i in {1..30}; do
      CURRENT_GPUS=$(docker exec "${NAME}" bash -lc "ray status --address=127.0.0.1:6380 2>/dev/null | grep 'GPU:' | awk -F'/' '{print \$2}' | awk '{print \$1}'" 2>/dev/null || echo "1")
      if [ "${CURRENT_GPUS:-1}" -ge "${TENSOR_PARALLEL}" ]; then
        log "  ✅ Sufficient GPUs available: ${CURRENT_GPUS}"
        break
      fi
      if [ $i -eq 30 ]; then
        log "  ⚠️  Proceeding with ${CURRENT_GPUS} GPU(s) - vLLM may fail if insufficient"
      fi
      sleep 1
    done
  fi
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step $(next_step): Starting vLLM server"
log ""

# Kill any existing vLLM processes
docker exec "${NAME}" bash -lc "pkill -f 'vllm serve' 2>/dev/null || true" || true

log "  Starting vLLM in background (this launches the server process)..."

# Start vLLM in background using nohup
# Note: We do NOT set HF_HUB_OFFLINE=1 here because workers need to resolve the model name
# The model should already be downloaded on all nodes via the pre-download step
docker exec "${NAME}" bash -lc "
  export HF_HOME=/root/.cache/huggingface
  export RAY_ADDRESS=127.0.0.1:6380
  export PYTHONUNBUFFERED=1
  export VLLM_LOGGING_LEVEL=INFO
  export VLLM_MXFP4_USE_MARLIN=1

  nohup vllm serve ${MODEL} \
    --distributed-executor-backend ray \
    --host 0.0.0.0 \
    --port 8000 \
    --tensor-parallel-size ${TENSOR_PARALLEL} \
    --max-model-len ${MAX_MODEL_LEN} \
    --gpu-memory-utilization ${GPU_MEMORY_UTIL} \
    --swap-space 16 \
    --enable-expert-parallel \
    --download-dir \$HF_HOME \
    > /var/log/vllm.log 2>&1 &

  sleep 1
" || true

log "  vLLM server process started"
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "  🔄 MODEL LOADING IN PROGRESS"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log ""
log "  This process typically takes 2-5 minutes depending on model size."
log "  The server will:"
log "    1. Load model weights into GPU memory"
log "    2. Initialize tensor parallelism across GPUs"
log "    3. Compile CUDA graphs for optimized inference"
log ""
log "  Progress updates will appear below..."
log ""

# Wait for vLLM to become ready with detailed progress feedback
VLLM_READY=false
MAX_WAIT=600  # 10 minutes max for very large models
LAST_STATUS=""
START_TIME=$(date +%s)

for i in $(seq 1 $MAX_WAIT); do
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))
  MINS=$((ELAPSED / 60))
  SECS=$((ELAPSED % 60))

  # Check if vLLM is ready
  if docker exec "${NAME}" bash -lc "curl -sf http://127.0.0.1:8000/health >/dev/null 2>&1"; then
    echo ""
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "  ✅ MODEL LOADED SUCCESSFULLY!"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log ""
    log "  vLLM is ready and accepting requests (loaded in ${MINS}m ${SECS}s)"
    log ""
    VLLM_READY=true
    break
  fi

  # Check vLLM process status and extract progress from logs
  VLLM_PID=$(docker exec "${NAME}" bash -lc "pgrep -f 'vllm serve' 2>/dev/null" || echo "")

  if [ -z "${VLLM_PID}" ]; then
    # vLLM process died - check logs for error
    echo ""
    log ""
    log "  ❌ vLLM process exited unexpectedly!"
    log ""
    log "  Last 20 lines of vLLM log:"
    docker exec "${NAME}" tail -20 /var/log/vllm.log 2>/dev/null || true
    log ""
    error "vLLM failed to start. Check logs: docker exec ${NAME} cat /var/log/vllm.log"
  fi

  # Parse last meaningful log line to show progress
  CURRENT_STATUS=$(docker exec "${NAME}" bash -lc "tail -50 /var/log/vllm.log 2>/dev/null | grep -E '(Loading|Loaded|weight|layer|graph|CUDA|tensor|parallel|shard|download|progress|INFO)' | tail -1 | sed 's/.*INFO/INFO/' | cut -c1-80" 2>/dev/null || echo "")

  # Show spinner with elapsed time
  SPINNER="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
  SPIN_CHAR="${SPINNER:$((i % 10)):1}"

  # Update progress display
  printf "\r  %s Loading model... [%dm %02ds elapsed]  " "${SPIN_CHAR}" "${MINS}" "${SECS}"

  # Show status updates when they change (avoid flooding terminal)
  if [ -n "${CURRENT_STATUS}" ] && [ "${CURRENT_STATUS}" != "${LAST_STATUS}" ]; then
    echo ""
    log "     ${CURRENT_STATUS}"
    LAST_STATUS="${CURRENT_STATUS}"
  fi

  # Periodic milestone messages
  if [ $((i % 60)) -eq 0 ]; then
    echo ""
    log "  ⏳ Still loading... (${MINS}m ${SECS}s) - this is normal for large models"
  fi

  sleep 1
done

# Handle timeout
if [ "${VLLM_READY}" != "true" ]; then
  echo ""
  log ""
  log "  ⚠️  vLLM not ready after $((MAX_WAIT / 60)) minutes"
  log ""
  log "  This could mean:"
  log "    - Model is still loading (very large models may need more time)"
  log "    - An error occurred during loading"
  log ""
  log "  Check the logs for details:"
  log "    docker exec ${NAME} tail -100 /var/log/vllm.log"
  log ""
  log "  You can also monitor GPU memory to see if loading is progressing:"
  log "    watch -n 1 nvidia-smi"
  log ""
fi

log ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step $(next_step): Running health checks"

# Check Ray status
RAY_NODES=$(docker exec "${NAME}" bash -lc "ray status --address=127.0.0.1:6380 2>/dev/null | grep 'Healthy:' -A1 | tail -1 | awk '{print \$1}'" || echo "0")
log "  Ray cluster: ${RAY_NODES} node(s) healthy"

# Check vLLM models
VLLM_MODEL=$(docker exec "${NAME}" bash -lc "curl -sf http://127.0.0.1:8000/v1/models 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"data\"][0][\"id\"])' 2>/dev/null" || echo "unknown")
log "  vLLM model: ${VLLM_MODEL}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Detect public-facing IP for user access (exclude loopback and docker bridge)
PUBLIC_IP=$(ip -o addr show | grep "inet " | grep -v "127.0.0.1" | grep -v "172.17" | awk '{print $4}' | cut -d'/' -f1 | head -1)
if [ -z "${PUBLIC_IP}" ]; then
  PUBLIC_IP="${HEAD_IP}"  # Fallback to IB IP if no other found
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ -n "${WORKER_HOST}" ]; then
  echo "✅ Cluster is ready! (Head + Worker orchestrated)"
else
  echo "✅ Head node is ready!"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "🌐 Services (accessible from network):"
echo "  Ray Dashboard:  http://${PUBLIC_IP}:8265"
echo "  vLLM API:       http://${PUBLIC_IP}:8000"
echo ""

if [ -n "${WORKER_HOST}" ]; then
  echo "🖥️  Cluster Nodes:"
  echo "  Head:   $(hostname) (${HEAD_IP})"
  echo "  Worker: ${WORKER_HOST}"
  echo ""
  echo "🔧 Worker Logs:"
  echo "  ssh ${WORKER_USER}@${WORKER_HOST} 'cat ~/worker_setup.log'"
  echo ""
else
  echo "🔗 Next Steps - Add Worker Nodes:"
  echo "  1. SSH to each worker node"
  echo "  2. Run: export HEAD_IP=${HEAD_IP}"
  echo "  3. Run: bash start_worker_vllm.sh"
  echo ""
  echo "  Note: Workers use IB/RoCE IP (${HEAD_IP}) for cluster communication"
  echo "  Note: Worker IPs and network interfaces will be auto-detected!"
  echo ""
  echo "  For orchestrated setup (single command), set WORKER_HOST:"
  echo "    export WORKER_HOST=<worker_ip>"
  echo "    bash start_head_vllm.sh"
  echo ""
fi

echo "📊 Quick API Tests:"
echo "  # List models"
echo "  curl http://${PUBLIC_IP}:8000/v1/models"
echo ""
echo "  # Chat completion"
echo "  curl http://${PUBLIC_IP}:8000/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"
echo ""
echo "🔍 Monitoring Commands:"
echo "  # View vLLM logs"
echo "  docker exec ${NAME} tail -f /var/log/vllm.log"
echo ""
echo "  # Ray cluster status (check for worker nodes)"
echo "  docker exec ${NAME} ray status --address=127.0.0.1:6380"
echo ""
echo "  # GPU utilization"
echo "  watch -n 1 nvidia-smi"
echo ""
echo "⚙️  Current Configuration:"
echo "  Model:              ${MODEL}"
echo "  Tensor Parallelism: ${TENSOR_PARALLEL} GPUs"
echo "  Max Context:        ${MAX_MODEL_LEN} tokens"
echo "  GPU Memory:         ${GPU_MEMORY_UTIL} utilization"
echo "  CUDA Graphs:        Enabled (optimized for performance)"
echo ""
echo "📊 Expected Performance:"
echo "  Throughput:         50-100 tokens/second"
echo "  First request:      May be slower (graph warmup)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
