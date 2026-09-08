#!/usr/bin/env bash
#
# Build aap-mcp-server container image from public upstream code.
#
# Reproduces what ships in
#   registry.redhat.io/ansible-automation-platform-tech-preview/mcp-server-rhel9
# but with these substitutions for an open/free build:
#   - Base image:    docker.io/rockylinux/rockylinux:9-minimal (auth-free)
#   - nginx module:  1.26 instead of 1.24 (newer LTS line)
#   - Telemetry:     Segment.io analytics OFF (entrypoint.sh strips
#                    ANALYTICS_KEY/CONTAINER_VERSION reads — analytics is a
#                    no-op at the source level when env var is empty)
#   - Logs:          stdout/stderr only (access_log /dev/stdout in nginx.conf,
#                    error_log /dev/stderr already in upstream config)
#
# Usage:
#   ./build.sh                          # local build for host arch
#   ./build.sh --push                   # multi-arch buildx push
#   ./build.sh --platform linux/arm64   # single-arch local build
#   ./build.sh --prep-only              # clone src/ + deps/, skip docker
#   ./build.sh --no-cache               # force fresh docker build
#
# Env overrides:
#   IMAGE_NAME=...        # default: quay.io/fitbeard/automation-platform/mcp-server
#   MCP_SERVER_SHA=...    # default: 03876616... (public main HEAD)
#   DUMB_INIT_TAG=...     # default: v1.2.5
#   IMAGE_TAG=...         # default: <short-sha>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"
DUMB_INIT_DIR="${SCRIPT_DIR}/deps/dumb-init"

# --- Upstream pins ----------------------------------------------------------
#
# We ship 03876616 (2026-09-02 "Fix CVE-2026-84375: js-yaml 4.3.2", public
# main HEAD at refresh time). Downstream tech-preview image
# mcp-server-rhel9:2.6.20260824-1787228159 is built from PRIVATE commit
# 97cf5c320f5e989b0967717083c1e966efc6539e (read from the image's own
# `vcs-ref` / `org.opencontainers.image.revision` labels) — that SHA is NOT on
# public github.com/ansible/aap-mcp-server, so RH now builds mcp-server from a
# private branch (same reality as the controller SRPM). No public commit to pin
# to; we track public main HEAD instead.
#
# Shipping public main HEAD is a security uplift over RH's ~2026-08-24 cut:
# adds fast-uri CVE-2026-75899/-75931 (Aug 27), MCP_PORT k8s service-link
# hardening AAP-90657 (Sep 2, relevant on k8s/kind), and js-yaml CVE-2026-84375
# (Sep 2) — while including RH's Aug content (ip-address CVE-2026-54272,
# fast-uri CVE-2026-16221, OpenAPI-spec sync Aug 21).
#
# Prior pin was a9281de4 (2026-05-08). RH-pin identification method: read the
# runtime image's vcs-ref label (no source-bundle fingerprinting needed now).

MCP_SERVER_URL="https://github.com/ansible/aap-mcp-server"
MCP_SERVER_SHA="${MCP_SERVER_SHA:-03876616275e34e779a539264341111088cc201a}"

DUMB_INIT_URL="https://github.com/Yelp/dumb-init"
DUMB_INIT_TAG="${DUMB_INIT_TAG:-v1.2.5}"

# --- Flags ------------------------------------------------------------------

PUSH=0
PREP_ONLY=0
LOCAL_PLATFORM=""
NOC_ARG=""

for arg in "$@"; do
    case "$arg" in
        --push)       PUSH=1 ;;
        --no-cache)   NOC_ARG="--no-cache" ;;
        --prep-only)  PREP_ONLY=1 ;;
        --platform)   shift; LOCAL_PLATFORM="$1"; shift ;;
        --platform=*) LOCAL_PLATFORM="${arg#*=}" ;;
        -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

IMAGE_NAME="${IMAGE_NAME:-quay.io/fitbeard/automation-platform/mcp-server}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER_NAME="mcp-server-multiarch"

# --- Preflight --------------------------------------------------------------

for cmd in git docker; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not in PATH" >&2; exit 1
    fi
done

# --- Wipe and re-clone ------------------------------------------------------

echo "==> Wiping ${SRC_DIR} and starting fresh"
rm -rf "$SRC_DIR"

echo "==> Cloning ${MCP_SERVER_URL}"
git clone --quiet "$MCP_SERVER_URL" "$SRC_DIR"
( cd "$SRC_DIR" && git checkout --quiet "$MCP_SERVER_SHA" )

SHORT_SHA="$(cd "$SRC_DIR" && git rev-parse --short=8 HEAD)"
IMAGE_TAG="${IMAGE_TAG:-$SHORT_SHA}"

echo "==> Wiping ${DUMB_INIT_DIR} and starting fresh"
rm -rf "$DUMB_INIT_DIR"
mkdir -p "$(dirname "$DUMB_INIT_DIR")"

echo "==> Cloning ${DUMB_INIT_URL} @ ${DUMB_INIT_TAG}"
git clone --quiet --depth 1 --branch "$DUMB_INIT_TAG" "$DUMB_INIT_URL" "$DUMB_INIT_DIR"

echo "==> Pinned versions:"
echo "    aap-mcp-server: $(cd "$SRC_DIR" && git log -1 --format='%h %ai - %s')"
echo "    dumb-init:      $(cd "$DUMB_INIT_DIR" && git log -1 --format='%h - %s')"

if [[ $PREP_ONLY -eq 1 ]]; then
    echo "==> --prep-only: skipping docker build"
    exit 0
fi

# --- Build -------------------------------------------------------------------

echo "==> Building ${IMAGE_NAME}:${IMAGE_TAG}"

BUILD_ARGS=(
    -t "${IMAGE_NAME}:${IMAGE_TAG}"
    -t "${IMAGE_NAME}:latest"
    -f "${SCRIPT_DIR}/Dockerfile"
)

if [[ $PUSH -eq 1 ]]; then
    if ! docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
        docker buildx create --name "${BUILDER_NAME}" --driver docker-container --use
    else
        docker buildx use "${BUILDER_NAME}"
    fi
    docker buildx inspect --bootstrap >/dev/null
    echo "==> Multi-arch push: ${PLATFORMS}"
    docker buildx build --platform "${PLATFORMS}" --push ${NOC_ARG} "${BUILD_ARGS[@]}" "${SCRIPT_DIR}"
else
    if [[ -n "$LOCAL_PLATFORM" ]]; then
        echo "==> Local build (platform=${LOCAL_PLATFORM})"
        docker buildx build --platform "${LOCAL_PLATFORM}" --load ${NOC_ARG} "${BUILD_ARGS[@]}" "${SCRIPT_DIR}"
    else
        echo "==> Local build (host platform)"
        docker build ${NOC_ARG} "${BUILD_ARGS[@]}" "${SCRIPT_DIR}"
    fi
    echo "==> Image: ${IMAGE_NAME}:${IMAGE_TAG}"
fi
