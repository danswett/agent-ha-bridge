#!/usr/bin/env bash
# Builds the native hook for every platform the bridge ships for, with SHA256SUMS:
#
#   hook/build-release.sh <version> <output-dir>
#
# The release workflow attaches what this produces; CI runs it on every push, so a
# build that would break a release fails there first. Asset names are what
# Get-BridgeNativeHookAsset (hooks/bridge-native-hook.ps1) asks for.
set -euo pipefail

version="${1:?usage: build-release.sh <version> <output-dir>}"
out="${2:?usage: build-release.sh <version> <output-dir>}"
cd "$(dirname "$0")"
mkdir -p "$out"

for target in windows/amd64 windows/arm64 darwin/amd64 darwin/arm64; do
  os="${target%/*}"; arch="${target#*/}"
  name="agent-bridge-hook-${os}-${arch}"
  [ "$os" = windows ] && name="${name}.exe"
  # The linker signs darwin/arm64 builds ad hoc, which Apple silicon requires.
  GOOS="$os" GOARCH="$arch" CGO_ENABLED=0 \
    go build -trimpath -ldflags "-s -w -X main.version=${version}" -o "${out}/${name}" .
done

(cd "$out" && sha256sum agent-bridge-hook-* > SHA256SUMS)
cat "${out}/SHA256SUMS"
