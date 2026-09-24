#!/bin/bash
# Format all Swift files in the repository using swift-format.
#
# Usage:
#   ./Scripts/format.sh          # Format files in-place
#   ./Scripts/format.sh --lint   # Check/lint without modifying files
#   ./Scripts/format.sh --check  # Alias for --lint

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v swift-format &>/dev/null; then
  echo "Error: swift-format is not installed or not in PATH." >&2
  echo "You can install it with: brew install swift-format" >&2
  exit 1
fi

CONFIG_FILE="${ROOT}/.swift-format"
CONFIG_ARGS=()
if [[ -f "$CONFIG_FILE" ]]; then
  CONFIG_ARGS=(--configuration "$CONFIG_FILE")
fi

# Targets to format (.build and external dependencies are excluded)
TARGETS=(
  Package.swift
  Sources
  Scripts
)

MODE="format"
if [[ "${1:-}" == "--lint" || "${1:-}" == "--check" ]]; then
  MODE="lint"
fi

if [[ "$MODE" == "lint" ]]; then
  echo "==> Linting Swift files with swift-format..."
  swift-format lint \
    -r -p \
    "${CONFIG_ARGS[@]}" \
    "${TARGETS[@]}"
  echo "==> All files passed linting."
else
  echo "==> Formatting Swift files with swift-format..."
  swift-format format \
    -i -r -p \
    "${CONFIG_ARGS[@]}" \
    "${TARGETS[@]}"
  echo "==> Formatting complete."
fi
