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
  Tests
)

MODE="format"
if [[ "${1:-}" == "--lint" ]]; then
  MODE="lint"
elif [[ "${1:-}" == "--check" ]]; then
  MODE="check"
fi

case "$MODE" in
lint)
  # Informational: swift-format's lint rules do not fully agree with the formatter under
  # lineBreakBeforeEachArgument = true, so CI uses --check instead.
  echo "==> Linting Swift files with swift-format..."
  swift-format lint \
    -r -p \
    "${CONFIG_ARGS[@]}" \
    "${TARGETS[@]}"
  echo "==> All files passed linting."
  ;;
check)
  # CI check: compare each file against formatter output without touching the working tree.
  echo "==> Checking formatting (swift-format $(swift-format --version | head -1))..."
  status=0
  while IFS= read -r -d '' file; do
    if ! diff -q "$file" <(swift-format format -p "${CONFIG_ARGS[@]}" "$file") >/dev/null; then
      echo "Not formatted: $file"
      status=1
    fi
  done < <(find "${TARGETS[@]}" -name '*.swift' -print0 | sort -z)
  if [[ "$status" -ne 0 ]]; then
    echo "==> Run ./Scripts/format.sh and commit the result." >&2
    exit 1
  fi
  echo "==> All files are formatted."
  ;;
*)
  echo "==> Formatting Swift files with swift-format..."
  swift-format format \
    -i -r -p \
    "${CONFIG_ARGS[@]}" \
    "${TARGETS[@]}"
  echo "==> Formatting complete."
  ;;
esac
