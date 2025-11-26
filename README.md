# Running vLLM on Two DGX Spark Units

This repository contains scripts and documentation for deploying vLLM across two NVIDIA DGX Spark servers for distributed inference.

## Background

We initially attempted to follow NVIDIA's playbook at https://build.nvidia.com/spark/vllm/stacked-sparks, but encountered numerous version compatibility issues. The solution documented here takes a different approach: starting with the NVIDIA vLLM Docker container and building up the correct versions of dependencies to achieve a working distributed setup.

## Architecture

- **Head Node**: Runs Ray cluster head + vLLM server with model serving
- **Worker Node(s)**: Join Ray cluster to provide additional GPU resources
- **Communication**: Uses InfiniBand (200Gb) for high-speed inter-node communication
- **Distribution**: Ray framework manages distributed inference across nodes

## Prerequisites

### On Both Head and Worker Nodes

1. **NVIDIA GPU Drivers**
   - NVIDIA drivers installed and working
   - Verify: `nvidia-smi`

2. **Docker with NVIDIA Container Runtime**
   - Docker installed
   - NVIDIA Container Runtime configured
   - Verify: `docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu20.04 nvidia-smi`

3. **Network Configuration**
   - **⚠️  CRITICAL:** InfiniBand (QSFP) interfaces must be configured and operational
   - InfiniBand interfaces: enp1s0f1np1, enP2p1s0f1np1 (DGX Spark specific)
   - InfiniBand IPs are typically in the 169.254.x.x range
   - Verify InfiniBand: `ibstatus` or `ip addr show | grep 169.254`
   - Both nodes can reach each other via InfiniBand IPs
   - Test IB connectivity: `ping <infiniband-ip-of-other-node>`
   - Firewall allows ports: 6379 (Ray), 8265 (Ray Dashboard), 8000 (vLLM API)
   - **Performance Note:** Using standard Ethernet IPs instead of InfiniBand will result in 10-20x slower performance
   - **Need help with InfiniBand setup?** See NVIDIA's guide: https://build.nvidia.com/spark/nccl/stacked-sparks

4. **Storage**
   - Sufficient disk space for models (70B models need ~140GB)
   - Default cache location: `/raid/hf-cache` (automatically created if needed)
   - To use a different location, set `HF_CACHE` environment variable before running scripts
   - **⚠️ IMPORTANT:** Fix HuggingFace cache permissions on both nodes (see step below)

5. **SSH Access**
   - SSH keys configured for passwordless login between nodes
   - Test: `ssh <worker-node-ip> hostname`

6. **HuggingFace Cache Permissions**

   Docker containers run as root and create files owned by root in the HF cache. This causes permission issues when syncing models between nodes. **Run this once on both nodes:**

   ```bash
   # On head node
   sudo chown -R $USER /raid/hf-cache

   # On worker node (replace with your worker IP)
   ssh <worker-ip> "sudo chown -R \$USER /raid/hf-cache"
   ```

   Alternatively, run `source ./setup-env.sh` which will detect and offer to fix permission issues automatically.

### Environment Configuration

The scripts now **auto-detect** most network configuration automatically using NVIDIA's `ibdev2netdev` tool. You only need to set a few variables:

#### Required Environment Variables

**On Head Node:**

```bash
# Required - only if you want to serve gated models
export HF_TOKEN="hf_your_token_here"        # HuggingFace token for gated models like Llama

# Optional overrides (all have sensible defaults or auto-detection)
export MODEL="meta-llama/Llama-3.3-70B-Instruct"  # Default model
export TENSOR_PARALLEL="2"                         # Number of GPUs across cluster
export MAX_MODEL_LEN="2048"                       # Context window size
export GPU_MEMORY_UTIL="0.70"                     # GPU memory utilization
```

**On Worker Node:**

```bash
# Required - must match the head node's InfiniBand IP
export HEAD_IP="169.254.x.x"             # Head node InfiniBand IP

# Everything else is auto-detected!
```

#### What Gets Auto-Detected

The scripts automatically detect and configure:
- ✅ **HEAD_IP**: Auto-detected from active InfiniBand interface (head node only)
- ✅ **WORKER_IP**: Auto-detected from active InfiniBand interface
- ✅ **Network Interfaces**: GLOO_IF, TP_IF, NCCL_IF, UCX_DEV
- ✅ **NCCL_IB_HCA**: InfiniBand HCAs (Host Channel Adapters)

The scripts use NVIDIA's recommended `ibdev2netdev` utility to find active InfiniBand interfaces and automatically configure all network settings.

#### Manual Override (Optional)

If you need to override auto-detection, you can still set these manually:

```bash
export HEAD_IP="169.254.x.x"             # Override head IP
export WORKER_IP="169.254.y.y"            # Override worker IP
export GLOO_IF="enp1s0f1np1"               # Override GLOO interface
export TP_IF="enp1s0f1np1"                 # Override TP interface
export NCCL_IF="enp1s0f1np1"               # Override NCCL interface
export UCX_DEV="enP2p1s0f1np1"             # Override UCX device
export NCCL_IB_HCA="rocep1s0f1,roceP2p1s0f1"  # Override IB HCAs
```

### Getting Your HuggingFace Token

1. Create account at https://huggingface.co/
2. Go to Settings → Access Tokens
3. Create a new token with read permissions
4. Accept terms for gated models (e.g., https://huggingface.co/meta-llama/Llama-3.3-70B-Instruct)

## Auto-Detection Features

Both scripts now include intelligent auto-detection using NVIDIA's `ibdev2netdev` utility:

### What Gets Auto-Detected

1. **InfiniBand IP Addresses**
   - Head node: Automatically detects HEAD_IP from active IB interface
   - Worker node: Automatically detects WORKER_IP from active IB interface
   - Prioritizes `enp1*` interfaces over `enP2p*` per NVIDIA best practices

2. **Network Interfaces**
   - GLOO_SOCKET_IFNAME (communication backend)
   - TP_SOCKET_IFNAME (tensor parallelism)
   - NCCL_SOCKET_IFNAME (collective communications)
   - UCX_NET_DEVICES (unified communication)

3. **InfiniBand HCAs**
   - Detects only active (Up) InfiniBand devices
   - Configures NCCL_IB_HCA with comma-separated list
   - Example: `rocep1s0f1,roceP2p1s0f1`

### How It Works

The scripts use `ibdev2netdev` to query InfiniBand device status:
```bash
$ ibdev2netdev
rocep1s0f1 port 1 ==> enp1s0f1np1 (Up)
roceP2p1s0f1 port 1 ==> enP2p1s0f1np1 (Up)
```

From this output, the scripts automatically:
- Extract active network interfaces
- Determine corresponding IP addresses
- Configure all NCCL/UCX environment variables
- Set up optimal InfiniBand communication

### Fallback Behavior

If `ibdev2netdev` is not available or detection fails:
- Uses sensible DGX Spark defaults
- Logs warnings for manual verification
- You can still override with environment variables

## Scripts Overview

### Deployment Scripts

#### 1. `start_head_vllm.sh` - Head Node Setup

The primary script for setting up the head node with vLLM distributed inference.

**Features:**
- **Auto-detects** InfiniBand IP and network interfaces using `ibdev2netdev`
- Pulls NVIDIA vLLM Docker image (nvcr.io/nvidia/vllm:25.10-py3)
- Starts container with InfiniBand support
- Installs Ray 2.51.0 (for version compatibility)
- Starts Ray head node
- Downloads the specified model
- Launches vLLM server with distributed backend
- **Enables InfiniBand/RoCE** with proper NCCL configuration

**Configuration (optional overrides):**
- `HF_TOKEN`: HuggingFace token for gated models
- `MODEL`: Which model to serve (default: Llama-3.3-70B-Instruct)
- `TENSOR_PARALLEL`: Number of GPUs across cluster (default: 2)
- `MAX_MODEL_LEN`: Context window size (default: 2048)
- `GPU_MEMORY_UTIL`: GPU memory utilization factor (default: 0.70)

**Usage:**
```bash
# Basic usage with auto-detection
./start_head_vllm.sh

# With custom model
export MODEL="meta-llama/Llama-3.1-405B-Instruct"
export TENSOR_PARALLEL=4
./start_head_vllm.sh
```

#### 2. `start_worker_vllm.sh` - Worker Node Setup

Sets up worker nodes to join the Ray cluster and provide additional GPU resources.

**Features:**
- **Auto-detects** worker IP and network interfaces
- Pulls the same Docker image as head
- Tests connectivity to head node before setup
- Starts container with InfiniBand support
- Installs matching Ray version
- Joins Ray cluster at head IP
- **Enables InfiniBand/RoCE** with proper NCCL configuration

**Required configuration:**
- `HEAD_IP`: Head node's InfiniBand IP (must be set manually)

**Usage:**
```bash
# Basic usage
export HEAD_IP=169.254.103.56
./start_worker_vllm.sh
```

#### 3. `test_vllm_cluster.sh` - Cluster Testing

Comprehensive test suite for validating your distributed vLLM cluster.

**Tests performed:**
- Container health checks
- Ray cluster connectivity
- GPU visibility and allocation
- vLLM API endpoint availability
- Inference functionality with sample prompts
- Response time and throughput measurements

**Usage:**
```bash
# Run all tests
./test_vllm_cluster.sh

# Check exit code
echo $?  # 0 = all tests passed
```

**Output:**
- Detailed test results for each component
- Summary of cluster health
- Performance metrics
- Recommendations for issues found

#### 4. `monitor_gpu_during_inference.sh` - GPU Utilization Monitor

Real-time GPU utilization monitoring during inference to identify performance bottlenecks (compute-bound vs network-bound).

**Features:**
- Monitors GPU utilization, memory, and power draw during inference
- Runs sample inference request while collecting metrics
- Calculates average GPU utilization
- Determines if bottleneck is compute or network
- Saves detailed logs for analysis

**Usage:**
```bash
# Monitor GPU during inference
./monitor_gpu_during_inference.sh [vllm_url]

# Default URL is http://localhost:8000
./monitor_gpu_during_inference.sh
```

**Output:**
- Real-time GPU metrics (sampled every 0.5s)
- Inference throughput (tokens/second)
- Average GPU utilization analysis
- Bottleneck identification (compute-bound vs network-bound)
- Detailed log file saved

#### 5. `benchmark_current_vllm.sh` - Performance Benchmarking with vllm bench serve

Uses the official `vllm bench serve` tool for consistent, reproducible benchmarks. Based on eugr's benchmarking methodology from the NVIDIA forums.

**Features:**
- Uses official vLLM benchmarking tool for accurate results
- ShareGPT dataset for realistic workload distribution (auto-downloads if missing)
- Measures Output token throughput, Peak throughput, TTFT, TPOT
- Single-request mode for latency testing
- Comparison against reference InfiniBand vs Ethernet performance

**Usage:**
```bash
# Full benchmark (100 prompts from ShareGPT dataset)
./benchmark_current_vllm.sh

# Single-request latency test
./benchmark_current_vllm.sh --single

# Quick benchmark (20 prompts)
./benchmark_current_vllm.sh --quick

# Custom prompts/concurrency with JSON output
./benchmark_current_vllm.sh -n 50 -c 50 -o results.json
```

**Options:**
| Option | Description |
|--------|-------------|
| `-u, --url URL` | vLLM API URL (default: auto-detect) |
| `-n, --num-prompts N` | Number of prompts to benchmark (default: 100) |
| `-c, --concurrency N` | Max concurrent requests (default: 100) |
| `-d, --dataset PATH` | Path to ShareGPT dataset JSON |
| `-s, --single` | Run single-request benchmark only |
| `-q, --quick` | Quick mode: 20 prompts, lower concurrency |
| `-o, --output FILE` | Output results to JSON file |
| `-h, --help` | Show help message |

**Performance Reference (Qwen3-30B-A3B, dual Spark):**
| Configuration | Ethernet | InfiniBand | Improvement |
|---------------|----------|------------|-------------|
| Tensor Parallel (tp=2) | 56 t/s | **76 t/s** | +36% |
| Batch (100 prompts) | ~410 t/s | ~707 t/s | +72% |

#### 6. `diagnose_nccl.sh` - NCCL/InfiniBand Diagnostic

Verifies that NCCL is properly configured to use InfiniBand/RoCE instead of falling back to standard Ethernet. Using IB/RoCE can provide 30-40% better performance.

**What it checks:**
- InfiniBand/RoCE device detection via ibdev2netdev
- RDMA/Verbs libraries (libibverbs, librdmacm)
- NCCL environment variables
- Network interface configuration
- NCCL transport selection (IB vs Socket)
- vLLM log analysis for NCCL issues

**Usage:**
```bash
# Check host system
./diagnose_nccl.sh

# Check inside ray-head container (recommended)
./diagnose_nccl.sh --container
```

**Example output:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NCCL/InfiniBand Diagnostic Report
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

▶ 1. InfiniBand/RoCE Device Detection
✓ ibdev2netdev command available
✓ InfiniBand/RoCE devices found:
    mlx5_0 port 1 ==> enp1s0f0np0 (Up)
    mlx5_1 port 1 ==> enp1s0f1np1 (Up)
✓ 2 active IB/RoCE device(s)

▶ 2. RDMA/Verbs Libraries
✓ libibverbs found
✓ librdmacm found
...
```

### Diagnostic Scripts

#### 7. `vllm_system_checkout.sh` - Comprehensive System Diagnostics

A complete diagnostic tool that collects all critical system information for troubleshooting performance and configuration issues.

**What it checks:**
- System information (OS, kernel, memory, CPU)
- GPU configuration on both local and remote nodes
- Docker container status and configuration
- Ray cluster status and resources
- Network configuration (Ethernet and InfiniBand)
- NCCL configuration and environment variables
- vLLM process information
- Docker logs and system resource usage

**Features:**
- Generates timestamped diagnostic reports
- Supports multi-node diagnostics via SSH
- Non-destructive (read-only operations)
- Detailed summary with key findings
- Colored output for easy reading

**Usage:**
```bash
# Basic usage (local node only)
./vllm_system_checkout.sh

# Full multi-node diagnostics (recommended)
export SECOND_DGX_HOST=spark-30e0
./vllm_system_checkout.sh

# Output saved to: vllm_diagnostic_report_YYYYMMDD_HHMMSS.log
```

**Use cases:**
- Troubleshooting performance issues (<5 tokens/s)
- Verifying InfiniBand/RoCE is being used
- Checking if both nodes are properly connected
- Validating NCCL network configuration
- Debugging GPU utilization problems
- Collecting information for support requests

#### 7. `check_infiniband.sh` - InfiniBand/RoCE Diagnostics

A focused diagnostic tool specifically for InfiniBand and RoCE network validation.

**What it checks:**
- InfiniBand hardware detection (Mellanox HCAs)
- InfiniBand tools installation (ibstat, ibstatus)
- InfiniBand kernel modules
- InfiniBand devices (/dev/infiniband)
- Network interfaces (ib0, ib1, or RoCE interfaces)
- InfiniBand port status and state
- NCCL environment variables for InfiniBand
- NCCL configuration in Ray containers

**Features:**
- Quick health check (runs in seconds)
- Clear pass/fail indicators
- Recommendations for fixing issues
- Shows recommended NCCL configuration

**Usage:**
```bash
# Run InfiniBand diagnostics
./check_infiniband.sh
```

**What to look for:**
- ✅ `NET/IB` in NCCL logs = InfiniBand/RoCE is working
- ❌ `NET/Socket` in NCCL logs = Falling back to Ethernet (slow!)

**Common issues detected:**
- InfiniBand tools not installed
- Network interfaces not configured
- NCCL not configured to use InfiniBand
- InfiniBand subnet manager not running

### Helper Scripts

#### 8. `deploy_to_workers.sh` - Automated Worker Deployment

Utility script for deploying the repository to multiple worker nodes via SSH.

**Features:**
- Uses rsync for efficient file transfer
- Preserves file permissions and timestamps
- Excludes unnecessary files (.git, logs, cache)

**Usage:**
```bash
# Edit the script to set your worker hostnames
# Then run:
./deploy_to_workers.sh
```

#### 9. `setup-env.sh` - Environment Setup

Sets up the common environment configuration used by other scripts.

**Use cases:**
- Source this in your shell for manual operations
- Used internally by deployment scripts

**Usage:**
```bash
# Source the environment
source ./setup-env.sh

# Now you have all variables set
echo $HEAD_IP
```

### Utility Scripts (Legacy)

The following scripts are from the parent directory and are included for reference:

- `qwen-235b-fp4-vllm.sh` - Example for running Qwen 235B with FP4 quantization
- `qwen-235b-vllm-optimized.sh` - Optimized configuration for Qwen 235B
- `start_worker_vllm_node.sh` - Simplified worker node startup

## Important: InfiniBand Network Configuration

**Before deploying, verify your InfiniBand network is working:**

### Finding Your InfiniBand IPs

On each DGX Spark node, run:
```bash
ip addr show | grep 169.254
```

Expected output should show interfaces with 169.254.x.x addresses:
```
inet 169.254.x.x/16 brd 169.254.255.255 scope global enp1s0f1np1
```

### Verifying InfiniBand Status

Check InfiniBand hardware status:
```bash
ibstatus
```

Expected output should show active ports:
```
Infiniband device 'mlx5_0' port 1 status:
    state: 4: ACTIVE
    physical state: 5: LinkUp
```

### Testing Inter-Node Connectivity

From head node, ping worker's InfiniBand IP:
```bash
ping 169.254.y.y  # Replace with your worker's IB IP
```

From worker node, ping head's InfiniBand IP:
```bash
ping 169.254.x.x  # Replace with your head's IB IP
```

**If InfiniBand is not working, DO NOT proceed.** The cluster will run but performance will be degraded by 10-20x.

Common InfiniBand issues:
- Cables not properly seated in QSFP ports
- InfiniBand subnet manager not running
- Incorrect network interface names

**Need help configuring InfiniBand between two DGX Spark units?**
See NVIDIA's NCCL over InfiniBand guide: https://build.nvidia.com/spark/nccl/stacked-sparks

## Deployment Steps

### Step 1: Prepare Head Node

1. SSH into the head node and clone this repository:
```bash
git clone https://github.com/mark-ramsey-ri/vllm-dgx-spark.git
cd vllm-dgx-spark
```

2. (Optional) Set your HuggingFace token if using gated models:
```bash
export HF_TOKEN="hf_your_token_here"
```

3. Run the head node setup - **network configuration is auto-detected**:
```bash
bash start_head_vllm.sh
```

The script will automatically:
- ✅ Detect your InfiniBand IP address
- ✅ Configure all network interfaces
- ✅ Set up NCCL for optimal InfiniBand performance

4. Wait for completion (may take 10-15 minutes for model download)

5. Verify the head is ready:
```bash
docker exec ray-head ray status --address=127.0.0.1:6379
```

Expected output: Should show "Healthy: 1 node"

**Note:** The script output will show all auto-detected values. Review them to ensure they're correct.

### Step 2: Prepare Worker Node(s)

**Option A: Run directly on worker**

1. SSH into the worker node and clone the repository:
```bash
git clone https://github.com/mark-ramsey-ri/vllm-dgx-spark.git
cd vllm-dgx-spark
```

2. Set the head node IP (this is the only required variable):
```bash
export HEAD_IP="169.254.x.x"  # Use the IP shown in head node output
```

**Note:** To find the head node IP, check the head node script output or run on head: `ip addr show | grep 169.254`

3. Run the worker setup - **everything else is auto-detected**:
```bash
bash start_worker_vllm.sh
```

The script will automatically:
- ✅ Detect worker's InfiniBand IP address
- ✅ Configure all network interfaces
- ✅ Set up NCCL for optimal InfiniBand performance

**Option B: Deploy from head node**

1. SSH to each worker and run with HEAD_IP:
```bash
ssh worker-hostname "export HEAD_IP=169.254.x.x && cd vllm-dgx-spark && bash start_worker_vllm.sh"
```

That's it! The worker will auto-detect its own configuration.

### Step 3: Verify Cluster

From the head node:

```bash
# Check Ray cluster
docker exec ray-head ray status --address=127.0.0.1:6379
```

Expected output: Should show "Healthy: 2 nodes" (or more if multiple workers)

```bash
# Run comprehensive tests
bash test_vllm_cluster.sh
```

### Step 4: Test Inference

```bash
# List available models
curl http://<HEAD_IP>:8000/v1/models

# Simple completion test
curl http://<HEAD_IP>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/Llama-3.3-70B-Instruct",
    "messages": [{"role": "user", "content": "Hello! How are you?"}],
    "max_tokens": 100
  }'
```

## Monitoring

### Ray Dashboard
- URL: `http://<HEAD_IP>:8265`
- View cluster nodes, resource usage, and task execution

### vLLM Logs
```bash
# On head node
docker exec ray-head tail -f /var/log/vllm.log
```

### GPU Monitoring
```bash
# Real-time GPU usage
watch -n 1 nvidia-smi

# Detailed GPU metrics
nvidia-smi dmon -s pucvmet
```

### Ray Status
```bash
# Check cluster health
docker exec ray-head ray status --address=127.0.0.1:6379

# On worker (shows connection status)
docker exec ray-worker-<hostname> ray status --address=<HEAD_IP>:6379
```

## Configuration Details

### Network Interfaces (Auto-Detected)

The scripts automatically detect and configure InfiniBand interfaces using `ibdev2netdev`:
- `GLOO_SOCKET_IFNAME` - Gloo communication backend (auto-detected)
- `TP_SOCKET_IFNAME` - Tensor parallelism communication (auto-detected)
- `NCCL_SOCKET_IFNAME` - NVIDIA Collective Communications (auto-detected)
- `UCX_NET_DEVICES` - Unified Communication X (auto-detected)
- `NCCL_IB_HCA` - InfiniBand HCAs (auto-detected from active devices)

The scripts prioritize `enp1*` interfaces over `enP2p*` interfaces per NVIDIA recommendations.

If you need to override auto-detection, set the environment variables before running the scripts.

### Docker Configuration

Key Docker parameters:
- `--network host`: Direct host networking for Ray
- `--gpus all`: Access to all GPUs
- `--shm-size=16g`: Large shared memory for model loading
- `--device=/dev/infiniband`: InfiniBand device access
- `--ulimit memlock=-1`: Unlimited locked memory for IB
- `--restart unless-stopped`: Auto-restart on failure

### Model Configuration

Adjust in `start_head_vllm.sh`:

```bash
MODEL="meta-llama/Llama-3.3-70B-Instruct"  # Model to serve
TENSOR_PARALLEL="2"                         # GPUs across cluster
MAX_MODEL_LEN="2048"                        # Context window
GPU_MEMORY_UTIL="0.70"                      # Memory utilization (70%)
```

For larger models or different configurations:
- Increase `TENSOR_PARALLEL` if using more GPUs
- Adjust `MAX_MODEL_LEN` for longer contexts (uses more memory)
- Tune `GPU_MEMORY_UTIL` (0.7-0.95) to balance memory usage

## Quick Start Guide

### For Impatient Users

```bash
# On head node (spark-6033)
git clone https://github.com/mark-ramsey-ri/vllm-dgx-spark.git
cd vllm-dgx-spark
export HF_TOKEN="hf_your_token_here"  # Only if using gated models
./start_head_vllm.sh

# Wait for completion, then on worker node (spark-30e0)
git clone https://github.com/mark-ramsey-ri/vllm-dgx-spark.git
cd vllm-dgx-spark
export HEAD_IP=169.254.103.56  # Use your head node's InfiniBand IP
./start_worker_vllm.sh

# Verify cluster
docker exec ray-head ray status --address=127.0.0.1:6379

# Test inference
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"meta-llama/Llama-3.3-70B-Instruct","messages":[{"role":"user","content":"Hello!"}]}'
```

That's it! Everything else is auto-detected.

## Performance Troubleshooting

### Low Throughput (<5 tokens/s)

If you're experiencing extremely low performance, the most common cause is **InfiniBand/RoCE not being used**.

**Quick diagnosis:**
```bash
# Run the InfiniBand diagnostic
./check_infiniband.sh

# Check vLLM logs for network mode
docker exec ray-head tail -100 /var/log/vllm.log | grep -E "NCCL|NET"
```

**What to look for:**
- ✅ **GOOD**: `NCCL INFO NET/IB` or `GPU Direct RDMA enabled` → Using InfiniBand/RoCE (~200 Gbps)
- ❌ **BAD**: `NCCL INFO NET/Socket` → Using Ethernet fallback (~10 Gbps = 20x slower!)

**Fix:**
The startup scripts now automatically enable InfiniBand/RoCE by setting `NCCL_IB_DISABLE=0`. If you're still experiencing issues:

1. **Run full diagnostics:**
   ```bash
   export SECOND_DGX_HOST=spark-30e0  # Your second node
   ./vllm_system_checkout.sh
   ```

2. **Check the diagnostic report** for:
   - Both Ray nodes showing as "Active"
   - NCCL environment showing `NCCL_IB_DISABLE=0`
   - InfiniBand devices detected

3. **Verify InfiniBand connectivity:**
   ```bash
   # Test bandwidth between nodes
   # On first node:
   ib_write_bw

   # On second node (replace IP):
   ib_write_bw 169.254.103.56
   ```

**Expected performance:**
- **Before fix (Ethernet)**: <5 tokens/s
- **After fix (InfiniBand/RoCE)**: 50-100 tokens/s for Llama-3.3-70B

For detailed information, see the [TROUBLESHOOTING.md](TROUBLESHOOTING.md) file.

## Troubleshooting

### Worker Cannot Connect to Head

```bash
# On worker, test connectivity
nc -zv <HEAD_IP> 6379

# Check firewall rules
sudo iptables -L | grep 6379

# Verify head is running
docker exec ray-head ray status --address=127.0.0.1:6379
```

### Version Mismatch Errors

Ensure Ray versions match between head and workers:
```bash
# Check Ray version
docker exec ray-head python3 -c "import ray; print(ray.__version__)"
docker exec ray-worker-<hostname> python3 -c "import ray; print(ray.__version__)"
```

Both should show `2.51.0`. If not, update `RAY_VERSION` environment variable.

### Out of Memory Errors

Reduce memory usage:
```bash
export GPU_MEMORY_UTIL="0.60"  # Lower from 0.70
export MAX_MODEL_LEN="1024"    # Reduce context window
```

Or use fewer GPUs per node and add more workers instead.

### Model Download Fails

```bash
# Test HuggingFace authentication
docker exec ray-head bash -c "
  export HF_TOKEN=hf_your_token
  huggingface-cli whoami
"

# Manual download
docker exec ray-head bash -c "
  export HF_TOKEN=hf_your_token
  huggingface-cli download meta-llama/Llama-3.3-70B-Instruct
"
```

### vLLM Server Not Starting

Check logs:
```bash
docker exec ray-head tail -100 /var/log/vllm.log
```

Common issues:
- Insufficient GPU memory → Reduce `GPU_MEMORY_UTIL` or `MAX_MODEL_LEN`
- Ray cluster not ready → Wait 30s after starting workers
- NCCL errors → Check InfiniBand configuration with `ibstatus`

## Performance Tips

1. **Use InfiniBand IPs**: Configure `HEAD_IP` and `WORKER_IP` to use IB interfaces (169.254.x.x range on DGX Spark)

2. **Optimize Tensor Parallelism**: Set `TENSOR_PARALLEL` to total GPUs across all nodes for maximum performance

3. **Tune Memory Utilization**: Start with `GPU_MEMORY_UTIL=0.70`, increase to 0.90 if stable

4. **Monitor GPU Usage**: Use `nvidia-smi dmon` to ensure all GPUs are utilized during inference

5. **Batch Requests**: vLLM automatically batches concurrent requests for better throughput

## API Usage Examples

### Python

```python
import openai

client = openai.OpenAI(
    base_url="http://<HEAD_IP>:8000/v1",
    api_key="not-needed"  # vLLM doesn't require authentication
)

response = client.chat.completions.create(
    model="meta-llama/Llama-3.3-70B-Instruct",
    messages=[
        {"role": "user", "content": "Explain quantum computing"}
    ],
    max_tokens=500
)

print(response.choices[0].message.content)
```

### Curl

```bash
curl http://<HEAD_IP>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/Llama-3.3-70B-Instruct",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "What is the capital of France?"}
    ],
    "temperature": 0.7,
    "max_tokens": 100
  }'
```

## Stopping the Cluster

### Stop Worker Node
```bash
docker stop ray-worker-<hostname>
docker rm ray-worker-<hostname>
```

### Stop Head Node
```bash
docker stop ray-head
docker rm ray-head
```

## Version Information

- **Base Image**: `nvcr.io/nvidia/vllm:25.10-py3`
- **Ray Version**: `2.51.0` (installed via pip, overrides container version)
- **Python**: 3.x (from container)
- **CUDA**: Included in NVIDIA container

## Alternative: TensorRT-LLM

For users interested in TensorRT-LLM as a potentially faster alternative to vLLM, we maintain a separate repository with comprehensive documentation and build scripts:

**Repository**: `~/trt-dgx-spark/` (separate from this vLLM repository)

**Key Info**:
- TensorRT-LLM can be 3-5x faster than vLLM for Llama-70B
- Requires building from source for DGX Spark GB10/SM120 GPU support
- Build time: 2-4 hours
- See `~/trt-dgx-spark/README.md` for complete documentation

---

## Contributing

Feel free to submit issues or pull requests for improvements.

## License

MIT License

## Acknowledgments

- Based on NVIDIA's vLLM container and DGX Spark architecture
- Inspired by NVIDIA's Stacked Sparks playbook (with significant modifications for compatibility)
