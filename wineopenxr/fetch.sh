#!/bin/sh
# Assemble wineopenxr's source tree: Valve's, at the same Proton commit lsteamclient pins,
# with crossover.patch applied. Only the patch is tracked here.
#
# Usage:
#   ./fetch.sh            assemble if needed
#   ./fetch.sh --refetch  discard the cached tarball and assembled tree first
#
# Overridable: PROTON_COMMIT, BASELINE_DIGEST, WORK, TREE

set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)

PROTON_COMMIT=${PROTON_COMMIT:-164e0ccd2ea2b1ec2e5d08dc97f65b184c2539ca}
# Same digest scheme as lsteamclient/fetch.sh, over Valve's wineopenxr directory.
BASELINE_DIGEST=${BASELINE_DIGEST:-7bbb5988bb6af15f2e3d9875593644ce715916e78028bef6e29f3d30a6ec913e}

# Shares lsteamclient's download of the same commit.
CACHE=${CACHE:-$repo/scratch/proton-lsc}
WORK=${WORK:-$repo/scratch/proton-wox}
TREE=${TREE:-$repo/build/wineopenxr}

if [ "${1:-}" = "--refetch" ]; then
	rm -rf "$WORK" "$TREE"
elif [ $# -ne 0 ]; then
	echo "==> unknown argument $1" >&2
	exit 1
fi

tarball=$CACHE/proton-$PROTON_COMMIT.tar.gz
base=$WORK/wineopenxr

if [ ! -d "$base" ]; then
	mkdir -p "$CACHE" "$WORK"
	if [ ! -f "$tarball" ]; then
		echo "==> fetching Proton $PROTON_COMMIT"
		curl -fsSL -o "$tarball.part" \
			"https://codeload.github.com/ValveSoftware/Proton/tar.gz/$PROTON_COMMIT"
		mv "$tarball.part" "$tarball"
	fi
	echo "==> extracting wineopenxr"
	rm -rf "$base.part"
	mkdir -p "$base.part"
	tar xzf "$tarball" -C "$base.part" --strip-components=2 "*/wineopenxr/"
	mv "$base.part" "$base"
fi

got=$(cd "$base" && python3 -c '
import hashlib, pathlib
root = pathlib.Path(".")
h = hashlib.sha256()
for p in sorted(q for q in root.rglob("*") if q.is_file()):
    h.update(hashlib.sha256(str(p.relative_to(root)).encode()).digest())
    h.update(hashlib.sha256(p.read_bytes()).digest())
print(h.hexdigest())
')

if [ "$got" != "$BASELINE_DIGEST" ]; then
	echo "==> baseline digest mismatch for Proton $PROTON_COMMIT wineopenxr" >&2
	echo "    expected $BASELINE_DIGEST" >&2
	echo "    got      $got" >&2
	echo "    ./fetch.sh --refetch to discard the cached tree." >&2
	exit 1
fi
echo "==> baseline verified: Proton $PROTON_COMMIT wineopenxr, $(find "$base" -type f | wc -l | tr -d ' ') files"

rm -rf "$TREE"
mkdir -p "$(dirname "$TREE")"
cp -c -R "$base" "$TREE" 2>/dev/null || cp -R "$base" "$TREE"
patch -p1 -d "$TREE" --forward -s < "$here/crossover.patch"
echo "==> assembled $TREE with crossover.patch applied"
