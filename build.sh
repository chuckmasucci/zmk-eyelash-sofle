#!/usr/bin/env bash
# Build the firmware locally in Docker, using the same targets as build.yaml.
# Usage: ./build.sh            build every target in build.yaml
#        ./build.sh left       build only targets whose shield matches "left"
#        ./build.sh --update   re-download ZMK/Zephyr sources first (happens automatically when config/west.yml changes)
set -euo pipefail

repo="$(cd "$(dirname "$0")" && pwd)"
# Same image the GitHub build uses (zmk build-user-config.yml).
image="zmkfirmware/zmk-build-arm:stable"

update=0
filter=""
for arg in "$@"; do
    case "$arg" in
        --update) update=1 ;;
        *) filter="$arg" ;;
    esac
done

mkdir -p "$repo/.zmk-workspace" "$repo/firmware"

docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e UPDATE="$update" \
    -e FILTER="$filter" \
    -v "$repo:/repo:ro" \
    -v "$repo/.zmk-workspace:/workspace" \
    -v "$repo/firmware:/firmware" \
    -w /workspace \
    "$image" bash -euo pipefail -c '
        # The repo root holds its own zephyr/ module folder, so the ZMK and
        # Zephyr sources live in a separate workspace instead of next to it.
        if [ ! -d .west ]; then
            mkdir -p manifest
            cp /repo/config/west.yml manifest/west.yml
            west init -l manifest
            UPDATE=1
        elif ! cmp -s /repo/config/west.yml manifest/west.yml; then
            cp /repo/config/west.yml manifest/west.yml
            UPDATE=1
        fi
        if [ "$UPDATE" = 1 ]; then
            west update --fetch-opt=--filter=tree:0
        fi
        # Registers Zephyr in $HOME, which is thrown away with the container.
        west zephyr-export >/dev/null

        python3 - <<EOF > targets.txt
import yaml
for t in yaml.safe_load(open("/repo/build.yaml"))["include"]:
    print("|".join([t["board"], t.get("shield", ""), t.get("snippet", ""), t.get("cmake-args", "")]))
EOF

        while IFS="|" read -r board shield snippet cmake_args; do
            [ -n "$FILTER" ] && [[ "$shield" != *"$FILTER"* ]] && continue
            name="${shield// /-}${shield:+-}$board"
            echo "=== Building $name"
            west build -p -s zmk/app -d "build/$name" -b "$board" \
                ${snippet:+-S "$snippet"} -- \
                ${shield:+-DSHIELD="$shield"} \
                -DZMK_CONFIG=/repo/config \
                -DZMK_EXTRA_MODULES=/repo \
                $cmake_args
            cp "build/$name/zephyr/zmk.uf2" "/firmware/$name-zmk.uf2"
        done < targets.txt
    '

echo "Firmware files are in $repo/firmware/"
