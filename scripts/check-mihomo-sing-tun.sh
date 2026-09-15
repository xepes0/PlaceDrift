#!/usr/bin/env bash
set -euo pipefail

MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.31}"
SING_TUN_VERSION="${SING_TUN_VERSION:-v0.4.24}"
PATCH_LEGACY_API="${PATCH_LEGACY_API:-0}"
WORKDIR="${RUNNER_TEMP:-/tmp}/wloc-mihomo-${MIHOMO_VERSION}-${SING_TUN_VERSION}"

rm -rf "$WORKDIR"
git clone --depth 1 --branch "$MIHOMO_VERSION" https://github.com/MetaCubeX/mihomo.git "$WORKDIR"
cd "$WORKDIR"

echo "Testing Mihomo $MIHOMO_VERSION with sing-tun $SING_TUN_VERSION"
go mod edit -replace="github.com/metacubex/sing-tun=github.com/metacubex/sing-tun@${SING_TUN_VERSION}"
go mod download github.com/metacubex/sing-tun

if [[ "$PATCH_LEGACY_API" == "1" ]]; then
  # sing-tun <= 0.4.22 predates this optional gVisor tuning field.
  # It is unrelated to loopback-address semantics, so removing the assignment
  # gives us a clean transport A/B build without backporting newer TUN code.
  python3 - <<'PY'
from pathlib import Path
p = Path("listener/sing_tun/server.go")
s = p.read_text()
needle = "\t\tEXP_ProcessorsPerChannel:              options.ProcessorsPerChannel,\n"
if needle not in s:
    raise SystemExit("expected EXP_ProcessorsPerChannel assignment not found")
p.write_text(s.replace(needle, "", 1))
PY
fi

go test ./listener/sing_tun

echo "compatible: Mihomo $MIHOMO_VERSION + sing-tun $SING_TUN_VERSION (legacy_patch=$PATCH_LEGACY_API)"
