#!/bin/sh
set -eu

# Xcode Cloud runs this script after cloning the repository.
# Build the Rust iOS bridge artifacts so Swift can link UniFFI symbols.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Installing Rust iOS targets"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim

echo "==> Building warp_ios_bridge xcframework and Swift bindings"
bash scripts/build_ios_xcframework.sh

echo "==> Rust bridge artifacts ready"
