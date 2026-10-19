#!/bin/sh
# Build wineopenxr: the x86_64 PE half with the wine tree's make, and the unix half by hand
# for the loader's arch, as lsteamclient/build.sh does and for the same reasons.
#
# The unix half links the native OpenXR loader (libopenxr_loader.dylib, built from Khronos'
# OpenXR-SDK-Source with openxr-loader-macos.patch) and is shipped next to it, so it finds
# whichever runtime XR_RUNTIME_JSON or the user's ~/.config/openxr/1/active_runtime.json names.
#
# Usage:
#   ./build.sh            build both halves into build/wineopenxr-out
#   ./build.sh --install  also install to the bridge, which the run script stages from
#                         on the next game launch, so Steam needn't restart
#
# Overridable: WINE_BUILD, WINE_SRC_REL, UNIX_ARCH, MIN_VER, CX_ROOT, OPENXR_LOADER, BRIDGE_DIR

set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)

WINE_BUILD=${WINE_BUILD:-$repo/scratch/wine-build-dual}
WINE_SRC_REL=${WINE_SRC_REL:-../wine}
UNIX_ARCH=${UNIX_ARCH:-arm64}
MIN_VER=${MIN_VER:-15.0}
TREE=${TREE:-$repo/build/wineopenxr}
OUT=${OUT:-$repo/build/wineopenxr-out}
OPENXR_LOADER=${OPENXR_LOADER:-$HOME/Source/OpenXR-SDK-Source/build/src/loader/libopenxr_loader.dylib}
BRIDGE_DIR=${BRIDGE_DIR:-$HOME/Library/Application Support/notproton/bridge}
install=0
[ "${1:-}" = "--install" ] && install=1
case "$UNIX_ARCH" in
	x86_64) unix_dir=x86_64-unix ;;
	arm64) unix_dir=aarch64-unix ;;
	*) echo "==> UNIX_ARCH is $UNIX_ARCH, expected x86_64 or arm64" >&2; exit 1 ;;
esac
# The unix half links against the runner's own ntdll.so, which has the loader's arch; the
# wine build tree only has one for the arch it was configured for.
if [ -z "${CX_ROOT:-}" ]; then
	for clone in "$HOME/Library/Application Support/notproton/runners"/crossover-*/CrossOver; do
		[ -d "$clone" ] && CX_ROOT=$clone
	done
fi
ntdll="${CX_ROOT:-}/lib/wine/$unix_dir/ntdll.so"
[ -f "$ntdll" ] || { echo "==> no $unix_dir/ntdll.so under CX_ROOT=${CX_ROOT:-unset}" >&2; exit 1; }
[ -f "$OPENXR_LOADER" ] || { echo "==> no OpenXR loader at $OPENXR_LOADER" >&2; exit 1; }
[ "$(lipo -archs "$OPENXR_LOADER")" = "$UNIX_ARCH" ] || { echo "==> $OPENXR_LOADER is not $UNIX_ARCH" >&2; exit 1; }

"$here/fetch.sh"

dll=dlls/wineopenxr
[ -d "$WINE_BUILD/$dll" ] || { echo "==> $WINE_BUILD has no $dll; run bridge/setup-wine-tree.sh" >&2; exit 1; }
cd "$WINE_BUILD"
src=$WINE_SRC_REL/$dll
rsync -a --delete "$TREE/" "$src/"

pe=$dll/x86_64-windows/wineopenxr.dll
echo "==> building $pe"
make "$pe" >/dev/null

echo "==> building the $UNIX_ARCH unix half"
mkdir -p "$dll/$unix_dir"
# The unix sources are the ones Makefile.in marks with "#pragma makedep unix".
objs=""
for c in $(grep -l "pragma makedep unix" "$src"/*.c); do
	o=$dll/$unix_dir/$(basename "${c%.c}").o
	clang -arch "$UNIX_ARCH" -mmacosx-version-min="$MIN_VER" -std=gnu23 -c -o "$o" "$c" \
		-I"$dll" -I"$src" -Iinclude -I"$WINE_SRC_REL/include" \
		-D__WINESRC__ -DWINE_UNIX_LIB -DWINE_NO_LONG_TYPES -fPIC -fasynchronous-unwind-tables -g -O2
	objs="$objs $o"
done
# D3D11 on DXMT's Metal half, which stays clear of Wine's headers.
for m in "$src"/*.m; do
	o=$dll/$unix_dir/$(basename "${m%.m}").o
	clang -arch "$UNIX_ARCH" -mmacosx-version-min="$MIN_VER" -fobjc-arc -c -o "$o" "$m" -fPIC -g -O2
	objs="$objs $o"
done
so=$dll/$unix_dir/wineopenxr.so
# shellcheck disable=SC2086
clang -arch "$UNIX_ARCH" -mmacosx-version-min="$MIN_VER" -dynamiclib -o "$so" $objs "$ntdll" \
	"$OPENXR_LOADER" -framework Metal -framework Foundation -Wl,-rpath,@loader_path -install_name @rpath/wineopenxr.so 2>&1 \
	| grep -v "was built for newer" || true
nm -u "$so" | grep -qE "_xrGetInstanceProcAddr$" || { echo "==> $so does not import the OpenXR loader" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/x86_64-windows" "$OUT/$unix_dir"
cp "$pe" "$OUT/x86_64-windows/"
cp "$so" "$OPENXR_LOADER" "$OUT/$unix_dir/"
cp "$src/wineopenxr64.json" "$OUT/"
echo "==> built into $OUT"
ls -la "$OUT"/*

[ "$install" -eq 1 ] || exit 0
mkdir -p "$BRIDGE_DIR/wineopenxr"
rsync -a --delete "$OUT/" "$BRIDGE_DIR/wineopenxr/"
echo "==> installed $BRIDGE_DIR/wineopenxr; each prefix stages it on its next game launch; Steam needn't restart"
