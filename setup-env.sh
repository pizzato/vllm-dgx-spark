#!/usr/bin/env bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# vLLM DGX Spark Environment Configuration Script (Simplified)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# With auto-detection enabled in the scripts, you only need to set:
# - HF_TOKEN (for gated models like Llama)
# - HEAD_IP (for worker nodes only)
#
# Usage:
#   source ./setup-env.sh           # Interactive mode
#   source ./setup-env.sh --head    # Head node mode
#   source ./setup-env.sh --worker  # Worker node mode
#
# NOTE: This script must be sourced (not executed) to set environment variables
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Check if script is being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "❌ Error: This script must be sourced, not executed"
    echo "   Usage: source ./setup-env.sh"
    exit 1
fi

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Helper function to prompt for input
prompt_input() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local is_secret="${4:-false}"
    local current_value="${!var_name:-}"

    # If variable is already set, use it
    if [ -n "$current_value" ]; then
        if [ "$is_secret" = true ]; then
            echo -e "${GREEN}✓${NC} $var_name already set (hidden)"
        else
            echo -e "${GREEN}✓${NC} $var_name=$current_value"
        fi
        return
    fi

    # Show prompt
    if [ -n "$default_value" ]; then
        echo -ne "${BLUE}?${NC} $prompt_text [${default_value}]: "
    else
        echo -ne "${YELLOW}!${NC} $prompt_text: "
    fi

    # Read input (with or without echo for secrets)
    if [ "$is_secret" = true ]; then
        read -s user_input
        echo ""  # New line after secret input
    else
        read user_input
    fi

    # Use default if no input provided
    if [ -z "$user_input" ] && [ -n "$default_value" ]; then
        user_input="$default_value"
    fi

    # Export the variable
    if [ -n "$user_input" ]; then
        export "$var_name=$user_input"
        if [ "$is_secret" = true ]; then
            echo -e "${GREEN}✓${NC} $var_name set (hidden)"
        else
            echo -e "${GREEN}✓${NC} $var_name=$user_input"
        fi
    else
        if [ -n "$default_value" ]; then
            echo -e "${YELLOW}⊘${NC} $var_name not set (will use default: $default_value)"
        else
            echo -e "${YELLOW}⊘${NC} $var_name not set (optional)"
        fi
    fi
}

# Detect node type from arguments
NODE_TYPE="interactive"
if [[ "$1" == "--head" ]]; then
    NODE_TYPE="head"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}HEAD NODE CONFIGURATION${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
elif [[ "$1" == "--worker" ]]; then
    NODE_TYPE="worker"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}WORKER NODE CONFIGURATION${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
else
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}vLLM DGX Spark - Environment Setup${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
fi

echo ""
echo "ℹ️  Note: Network configuration (IPs, interfaces, HCAs) is now auto-detected!"
echo "   You only need to provide the essential configuration below."
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Fix HuggingFace Cache Permissions (Required)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

HF_CACHE="${HF_CACHE:-/raid/hf-cache}"
echo -e "${YELLOW}Checking HuggingFace cache permissions...${NC}"

# Check if HF cache exists and fix permissions if needed
if [ -d "$HF_CACHE" ]; then
    if [ ! -w "$HF_CACHE" ]; then
        echo -e "${RED}⚠${NC}  HF cache at $HF_CACHE is not writable by current user"
        echo "   Docker containers run as root and may have created files owned by root."
        echo ""
        echo -e "${YELLOW}To fix permissions, run:${NC}"
        echo "   sudo chown -R \$USER $HF_CACHE"
        echo ""
        read -p "Would you like to fix permissions now? (requires sudo) [y/N]: " fix_perms
        if [[ "$fix_perms" =~ ^[Yy]$ ]]; then
            echo "Running: sudo chown -R $USER $HF_CACHE"
            if sudo chown -R "$USER" "$HF_CACHE"; then
                echo -e "${GREEN}✓${NC} Permissions fixed successfully"
            else
                echo -e "${RED}✗${NC} Failed to fix permissions. Please run manually:"
                echo "   sudo chown -R \$USER $HF_CACHE"
            fi
        fi
    else
        echo -e "${GREEN}✓${NC} HF cache permissions OK ($HF_CACHE)"
    fi
else
    echo -e "${BLUE}ℹ${NC}  HF cache directory will be created at $HF_CACHE"
fi
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Head Node Configuration
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [[ "$NODE_TYPE" == "head" ]] || [[ "$NODE_TYPE" == "interactive" ]]; then
    echo -e "${GREEN}Head Node Settings:${NC}"
    echo ""

    # HuggingFace Token (required for gated models)
    echo "HuggingFace Token (required for gated models like Llama):"
    echo "  Get yours at: https://huggingface.co/settings/tokens"
    prompt_input "HF_TOKEN" "Enter your HuggingFace token" "" true
    echo ""

    # Optional model configuration
    echo -e "${BLUE}Optional Configuration (press Enter to use defaults):${NC}"
    prompt_input "MODEL" "Model to serve" "openai/gpt-oss-120b"
    prompt_input "TENSOR_PARALLEL" "Number of GPUs (tensor parallel size)" "2"
    prompt_input "MAX_MODEL_LEN" "Maximum context length (tokens)" "8192"
    prompt_input "GPU_MEMORY_UTIL" "GPU memory utilization (0.0-1.0)" "0.90"
    echo ""
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Worker Node Configuration
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [[ "$NODE_TYPE" == "worker" ]] || [[ "$NODE_TYPE" == "interactive" ]]; then
    echo -e "${BLUE}Worker Node Settings:${NC}"
    echo ""

    # HEAD_IP (required for workers)
    echo "Head Node IP (required):"
    echo "  This should be the InfiniBand IP from your head node"
    echo "  Example: 169.254.x.x"
    prompt_input "HEAD_IP" "Enter head node InfiniBand IP" ""
    echo ""
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Summary
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Configuration Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Variables set in your current shell session:"
echo ""

if [[ "$NODE_TYPE" == "head" ]] || [[ "$NODE_TYPE" == "interactive" ]]; then
    [ -n "${HF_TOKEN:-}" ] && echo "  ✓ HF_TOKEN (hidden)"
    [ -n "${MODEL:-}" ] && echo "  ✓ MODEL=$MODEL"
    [ -n "${TENSOR_PARALLEL:-}" ] && echo "  ✓ TENSOR_PARALLEL=$TENSOR_PARALLEL"
    [ -n "${MAX_MODEL_LEN:-}" ] && echo "  ✓ MAX_MODEL_LEN=$MAX_MODEL_LEN"
    [ -n "${GPU_MEMORY_UTIL:-}" ] && echo "  ✓ GPU_MEMORY_UTIL=$GPU_MEMORY_UTIL"
fi

if [[ "$NODE_TYPE" == "worker" ]] || [[ "$NODE_TYPE" == "interactive" ]]; then
    [ -n "${HEAD_IP:-}" ] && echo "  ✓ HEAD_IP=$HEAD_IP"
fi

echo ""
echo "Auto-detected by scripts (no configuration needed):"
echo "  ✓ HEAD_IP (head node only) - detected from InfiniBand"
echo "  ✓ WORKER_IP - detected from InfiniBand"
echo "  ✓ Network interfaces (GLOO_IF, TP_IF, NCCL_IF, UCX_DEV)"
echo "  ✓ InfiniBand HCAs (NCCL_IB_HCA)"
echo ""
echo "Next steps:"
if [[ "$NODE_TYPE" == "head" ]]; then
    echo "  Run: bash start_head_vllm.sh"
elif [[ "$NODE_TYPE" == "worker" ]]; then
    echo "  Run: bash start_worker_vllm.sh"
else
    echo "  Head node: bash start_head_vllm.sh"
    echo "  Worker node: bash start_worker_vllm.sh"
fi
echo ""
