#!/usr/bin/env bash
# validate-envoy-config.sh — Validate Envoy proxy YAML configuration files.
#
# Usage:
#   ./validate-envoy-config.sh <config-file> [envoy-binary]
#
# Examples:
#   ./validate-envoy-config.sh envoy.yaml
#   ./validate-envoy-config.sh /etc/envoy/envoy.yaml /usr/local/bin/envoy
#   ./validate-envoy-config.sh bootstrap.yaml envoy  # envoy on PATH
#
# Requirements:
#   - Envoy binary (default: looks for 'envoy' on PATH, or uses Docker fallback)
#
# Exit codes:
#   0 — Configuration is valid
#   1 — Configuration is invalid or envoy not found

set -euo pipefail

CONFIG_FILE="${1:-}"
ENVOY_BIN="${2:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
  echo "Usage: $0 <config-file> [envoy-binary]"
  echo ""
  echo "Validates an Envoy proxy YAML configuration file."
  echo ""
  echo "Arguments:"
  echo "  config-file    Path to the Envoy YAML config file"
  echo "  envoy-binary   Path to the envoy binary (optional; defaults to 'envoy' on PATH)"
  echo ""
  echo "If envoy is not found locally, falls back to Docker:"
  echo "  envoyproxy/envoy:v1.31-latest"
  exit 1
}

if [[ -z "$CONFIG_FILE" ]]; then
  usage
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo -e "${RED}ERROR:${NC} Config file not found: $CONFIG_FILE"
  exit 1
fi

# Resolve to absolute path
CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"

find_envoy() {
  if [[ -n "$ENVOY_BIN" ]]; then
    if command -v "$ENVOY_BIN" &>/dev/null || [[ -x "$ENVOY_BIN" ]]; then
      echo "$ENVOY_BIN"
      return 0
    fi
    echo -e "${YELLOW}WARNING:${NC} Specified envoy binary not found: $ENVOY_BIN" >&2
  fi

  if command -v envoy &>/dev/null; then
    echo "envoy"
    return 0
  fi

  return 1
}

validate_with_envoy() {
  local envoy_cmd="$1"
  echo -e "${YELLOW}Validating:${NC} $CONFIG_FILE"
  echo -e "${YELLOW}Using:${NC}      $envoy_cmd"
  echo ""

  if $envoy_cmd --mode validate -c "$CONFIG_FILE" 2>&1; then
    echo ""
    echo -e "${GREEN}✓ Configuration is valid${NC}"
    return 0
  else
    echo ""
    echo -e "${RED}✗ Configuration is invalid${NC}"
    return 1
  fi
}

validate_with_docker() {
  local image="envoyproxy/envoy:v1.31-latest"
  local config_dir
  config_dir="$(dirname "$CONFIG_FILE")"
  local config_name
  config_name="$(basename "$CONFIG_FILE")"

  echo -e "${YELLOW}Validating:${NC} $CONFIG_FILE"
  echo -e "${YELLOW}Using:${NC}      Docker image $image"
  echo ""

  if docker run --rm \
    -v "${config_dir}:/etc/envoy:ro" \
    "$image" \
    envoy --mode validate -c "/etc/envoy/${config_name}" 2>&1; then
    echo ""
    echo -e "${GREEN}✓ Configuration is valid${NC}"
    return 0
  else
    echo ""
    echo -e "${RED}✗ Configuration is invalid${NC}"
    return 1
  fi
}

# Try native envoy first, fall back to Docker
if envoy_path="$(find_envoy)"; then
  validate_with_envoy "$envoy_path"
elif command -v docker &>/dev/null; then
  echo -e "${YELLOW}INFO:${NC} Envoy binary not found, falling back to Docker..."
  validate_with_docker
else
  echo -e "${RED}ERROR:${NC} Neither envoy binary nor Docker found."
  echo "Install Envoy or Docker to validate configs."
  exit 1
fi
