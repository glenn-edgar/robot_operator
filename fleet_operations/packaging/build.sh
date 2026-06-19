#!/bin/bash
# packaging/build.sh — stage prebuilt .so files and build the container image.
#
# Run from anywhere; resolves paths relative to the script.
#
# Today: native amd64 (no --platform). For arm64 Pi deploy later, run with
# DOCKER_BUILDX=1 and pass --platform=linux/arm64 (TODO: separate script).

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ASSETS_DIR=$SCRIPT_DIR/build_assets
LIB_DIR=$ASSETS_DIR/lib

# Where the .so files live on the bench (WSL). Override with env if elsewhere.
# As of 2026-05-25 the canonical libzenoh_rpc.so has the refcount UAF fix
# (closure-context use-after-free that was crashing application_gateway
# ~once/hour); see zenoh_rpc_uaf_fix_2026-05-25 memory for context.
ZENOH_PICO_DIR=${ZENOH_PICO_DIR:-$HOME/src/zenoh-pico/lib-combined}
ZENOH_SHIM_DIR=${ZENOH_SHIM_DIR:-$HOME/knowledge_base_assembly/luajit_programs_and_containers/building_blocks/knowledge_base/zenoh}

# Per-lib overrides if someone wants to point at a different build
# (e.g., zenoh_libs/c/rpc/build/ for an in-progress patch).
ZENOH_RPC_SO=${ZENOH_RPC_SO:-$ZENOH_SHIM_DIR/libzenoh_rpc.so}
ZENOH_PUBSUB_SO=${ZENOH_PUBSUB_SO:-$ZENOH_SHIM_DIR/libzenoh_pubsub.so}
ZENOH_TOKEN_SO=${ZENOH_TOKEN_SO:-$ZENOH_SHIM_DIR/libzenoh_token.so}

IMAGE_TAG=${IMAGE_TAG:-fleet-mcfarland:wsl}

# ----------------------------------------------------------------------------
# Stage prebuilt zenoh shared libs into the docker build context.
# ----------------------------------------------------------------------------
echo "==> Staging prebuilt zenoh .so files into $LIB_DIR"
mkdir -p "$LIB_DIR"
rm -f "$LIB_DIR"/*.so

for src in \
    "$ZENOH_PICO_DIR/libzenohpico.so" \
    "$ZENOH_PUBSUB_SO" \
    "$ZENOH_RPC_SO" \
    "$ZENOH_TOKEN_SO" \
    ; do
    if [ ! -f "$src" ]; then
        echo "ERROR: missing $src" >&2
        echo "Set ZENOH_PICO_DIR / ZENOH_SHIM_DIR / ZENOH_*_SO to override defaults." >&2
        exit 1
    fi
    cp "$src" "$LIB_DIR/"
done

ls -la "$LIB_DIR"

# ----------------------------------------------------------------------------
# Build the image. Context is the repo root so the Dockerfile can COPY in
# robot_common/, vendor/, server/, etc.
# ----------------------------------------------------------------------------
echo "==> docker build -t $IMAGE_TAG (context=$REPO_ROOT)"
cd "$REPO_ROOT"
docker build -f packaging/Dockerfile -t "$IMAGE_TAG" .

echo "==> done. image: $IMAGE_TAG"
docker images "$IMAGE_TAG"
