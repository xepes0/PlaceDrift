#!/usr/bin/env bash
set -euo pipefail

VARIANT="${1:-current}"
MIHOMO_REF="${MIHOMO_REF:-v1.19.31}"
PROXYCAT_REF="${PROXYCAT_REF:-main}"
WORKROOT="${RUNNER_TEMP:-/tmp}/wloc-libmihomo-${VARIANT}"
OUT_DIR="${OUT_DIR:-$PWD/dist/libmihomo-${VARIANT}}"

case "$VARIANT" in
  legacy)
    SING_TUN_VERSION="v0.4.21"
    PATCH_LEGACY_API=1
    ;;
  current)
    SING_TUN_VERSION="v0.4.24"
    PATCH_LEGACY_API=0
    ;;
  *)
    echo "usage: $0 [legacy|current]" >&2
    exit 2
    ;;
esac

rm -rf "$WORKROOT" "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "==> Clone proxycat build wrapper"
git clone --depth 1 --branch "$PROXYCAT_REF" https://github.com/MMitsuha/proxycat.git "$WORKROOT/proxycat"
cd "$WORKROOT/proxycat"

git submodule update --init --recursive mihomo

# proxycat tracks its own Mihomo fork as the submodule origin. For the A/B
# experiment we intentionally pin the public MetaCubeX release tag instead.
echo "==> Pin upstream Mihomo: $MIHOMO_REF"
git -C mihomo fetch --depth 1 https://github.com/MetaCubeX/mihomo.git \
  "refs/tags/${MIHOMO_REF}:refs/tags/${MIHOMO_REF}"
git -C mihomo checkout --detach "refs/tags/${MIHOMO_REF}"

echo "==> Override sing-tun: $SING_TUN_VERSION"
cd libmihomo
go mod edit -replace="github.com/metacubex/sing-tun=github.com/metacubex/sing-tun@${SING_TUN_VERSION}"
cd ..

if [[ "$PATCH_LEGACY_API" == "1" ]]; then
  echo "==> Remove the post-0.4.22 optional processor tuning assignment"
  python3 - <<'PY'
from pathlib import Path
p = Path("mihomo/listener/sing_tun/server.go")
s = p.read_text()
needle = "\t\tEXP_ProcessorsPerChannel:              options.ProcessorsPerChannel,\n"
if needle not in s:
    raise SystemExit("expected EXP_ProcessorsPerChannel assignment not found")
p.write_text(s.replace(needle, "", 1))
PY
fi

echo "==> Build device XCFramework: mihomo=$MIHOMO_REF sing-tun=$SING_TUN_VERSION"
./scripts/build-libmihomo.sh device

cp -R Frameworks/Libmihomo.xcframework "$OUT_DIR/Libmihomo.xcframework"
cat > "$OUT_DIR/BUILD-INFO.txt" <<EOF
variant=$VARIANT
mihomo=$MIHOMO_REF
sing-tun=$SING_TUN_VERSION
legacy_api_patch=$PATCH_LEGACY_API
proxycat_ref=$PROXYCAT_REF
mihomo_commit=$(git -C mihomo rev-parse HEAD)
proxycat_commit=$(git rev-parse HEAD)
EOF

echo "==> Output"
cat "$OUT_DIR/BUILD-INFO.txt"
du -sh "$OUT_DIR/Libmihomo.xcframework"
