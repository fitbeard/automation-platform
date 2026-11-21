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
#   MCP_SERVER_SHA=...    # default: 1108adb... (newest SDK-v1 public main)
#   DUMB_INIT_TAG=...     # default: v1.2.5
#   IMAGE_TAG=...         # default: <short-sha>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"
DUMB_INIT_DIR="${SCRIPT_DIR}/deps/dumb-init"

# --- Upstream pins ----------------------------------------------------------
#
# We ship 1108adb (2026-09-22 "Merge #197 AAP-88192 schedule CRUD tools") —
# the last SDK-v1 commit on public main before the MCP SDK v1->v2 migration
# merged (661dc63, 2026-09-25). The vendor's tech-preview runtime image
# (tag 2.6.20260923-1789669036) is built from commit
# a41e7d46b3396f6439ea32f3e330be9c7fa94e28 (read from the image's own
# `vcs-ref`/`org.opencontainers.image.revision` labels; version 2.6.20260923) —
# that commit is NOT on public github.com/ansible/aap-mcp-server. Confirmed from
# the -source container's materialized build-wrapper tree: the vendored branch is
# still on @modelcontextprotocol/sdk ^1.26.0 (SDK v1) + js-yaml 4.3.2, and has
# DIVERGED from public main (it still carries session-era src/session.ts, which
# public removed, and lacks public's src/oauth2/). So no public commit matches
# the vendored tree exactly — same situation as the controller sources.
#
# Pin policy (user decision, refresh wave 2): VENDOR-PARITY, not bleeding edge.
# The vendored 2.6.20260923 build is still SDK v1 with no "skills" feature, so we
# pin to the newest SDK-v1 public main commit (1108adb) rather than public HEAD
# (174a0801+), which has already migrated to MCP SDK v2 + Express 5 + the
# SEP-2640 skills extension — features the vendor has not shipped. Staying SDK v1
# keeps behavioural parity with the vendored build while still taking every
# pre-v2 security/functional fix.
#
# Uplift over our prior pin 03876616 (2026-09-02), all SDK v1:
#   - fast-uri 3.1.7 (CVE-2026-84292, #192)
#   - skip empty/null optional query params in buildToolUrl (AAP-90617, #190)
#   - full schedule CRUD in the job_management toolset (AAP-88192, #197)
# Dockerfile/tsconfig/node (>=22) unchanged vs 03876616 — builds as-is.
#
# Vendored-pin identification: read the runtime image's vcs-ref label. The
# -source container additionally lets us confirm SDK major + divergence (done
# above); for routine bumps the runtime label + /app diff is enough.

MCP_SERVER_URL="https://github.com/ansible/aap-mcp-server"
MCP_SERVER_SHA="${MCP_SERVER_SHA:-1108adb8309fb4da566285479a11c0b9f0f90469}"

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
