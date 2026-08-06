#!/usr/bin/env bash
# Local mirror of the GitHub Actions build (zmkfirmware/zmk build-user-config@v0.3).
# Produces the same .uf2 files you'd download from the workflow artifact.
#
# Usage:
#   ./build.sh              build every target in the matrix
#   ./build.sh left         build a single target (left | right | reset)
#   ./build.sh --pristine   force a clean CMake configure
#   ./build.sh --update     re-run `west update` (after changing config/west.yml)
#   ./build.sh --nuke       delete the cached Zephyr workspace volume
#
# The Zephyr workspace (zmk/, modules/, .west/) lives in a Docker volume so the
# repo stays clean and `west update` only runs once.

set -euo pipefail

IMAGE="zmkfirmware/zmk-build-arm:stable"
VOLUME="zmk-workspace-$(basename "$PWD")"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$REPO/firmware"

# Mirrors build.yaml: name|board|shield|snippet
TARGETS=(
  "left|nice_nano_v2|corne_left nice_view_adapter nice_view|studio-rpc-usb-uart"
  "right|nice_nano_v2|corne_right nice_view_adapter nice_view|"
  "reset|nice_nano_v2|settings_reset|"
)

PRISTINE=""
UPDATE=""
WANTED=()

for arg in "$@"; do
  case "$arg" in
    --pristine) PRISTINE="--pristine" ;;
    --update)   UPDATE=1 ;;
    --nuke)     docker volume rm -f "$VOLUME"; echo "removed volume $VOLUME"; exit 0 ;;
    -*)         echo "unknown flag: $arg" >&2; exit 1 ;;
    *)          WANTED+=("$arg") ;;
  esac
done

docker volume create "$VOLUME" >/dev/null
mkdir -p "$OUT"

run() {
  docker run --rm \
    -v "$VOLUME:/ws" \
    -v "$REPO/config:/ws/config" \
    -v "$OUT:/out" \
    -e ZEPHYR_BASE=/ws/zephyr \
    -e HOME=/ws/home \
    -w /ws \
    "$IMAGE" bash -euo pipefail -c "$1"
}

# One-time (or --update) workspace init.
# zephyr-export writes the CMake package registry into $HOME, which is why HOME
# points inside the volume — otherwise it vanishes with the --rm container and
# zmk/app's `find_package(Zephyr ... HINTS ../zephyr)` cannot resolve.
if [ -n "$UPDATE" ] || ! docker run --rm -v "$VOLUME:/ws" "$IMAGE" \
     test -d /ws/home/.cmake/packages/Zephyr; then
  echo "==> west init/update (first run downloads ~1.5GB)"
  run '
    mkdir -p /ws/home
    [ -d .west ] || west init -l config
    west update
    west zephyr-export
  '
fi

for entry in "${TARGETS[@]}"; do
  IFS='|' read -r name board shield snippet <<<"$entry"

  if [ ${#WANTED[@]} -gt 0 ]; then
    match=""
    for w in "${WANTED[@]}"; do [ "$w" = "$name" ] && match=1; done
    [ -n "$match" ] || continue
  fi

  artifact="$(echo "$shield" | cut -d' ' -f1)-${board}-zmk"
  echo "==> building $artifact"

  snippet_arg=""
  [ -n "$snippet" ] && snippet_arg="-S $snippet"

  run "
    west build -s zmk/app -d build/$name -b $board $PRISTINE $snippet_arg \
      -- -DSHIELD='$shield' -DZMK_CONFIG=/ws/config
    cp build/$name/zephyr/zmk.uf2 /out/$artifact.uf2
  "
done

echo
echo "==> firmware in $OUT"
ls -lh "$OUT"
