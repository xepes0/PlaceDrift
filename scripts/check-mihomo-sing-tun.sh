#!/usr/bin/env bash
set -euo pipefail

MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.31}"
SING_TUN_VERSION="${SING_TUN_VERSION:-v0.4.24}"
WORKDIR="${RUNNER_TEMP:-/tmp}/wloc-mihomo-${MIHOMO_VERSION}-${SING_TUN_VERSION}"

rm -rf "$WORKDIR"
git clone --depth 1 --branch "$MIHOMO_VERSION" https://github.com/MetaCubeX/mihomo.git "$WORKDIR"
cd "$WORKDIR"

echo "Testing Mihomo $MIHOMO_VERSION with sing-tun $SING_TUN_VERSION"
go mod edit -replace="github.com/metacubex/sing-tun=github.com/metacubex/sing-tun@${SING_TUN_VERSION}"
go mod download github.com/metacubex/sing-tun

go test ./listener/sing_tun

echo "compatible: Mihomo $MIHOMO_VERSION + sing-tun $SING_TUN_VERSION"
