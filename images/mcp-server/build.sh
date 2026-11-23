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
SKILLS_DIR="${SCRIPT_DIR}/skills"
DUMB_INIT_DIR="${SCRIPT_DIR}/deps/dumb-init"

# --- Upstream pins ----------------------------------------------------------
#
# The vendor's mcp-server (mcp-server-rhel9, version 2.7.20261111, runtime
# vcs-ref 78e5738 — NOT a public ref, same as prior waves) has MIGRATED to MCP SDK
# v2 (@modelcontextprotocol/{node,server,client} ^2.x + Express 5) and now ships
# the "skills" feature: it bundles the public `ansible/aap-skills` SKILL.md
# knowledge packages served THROUGH the server. So the wave-2 "stay SDK-v1 for
# vendor parity" rationale no longer holds — 2.7 parity IS SDK v2 + skills.
#
# Pin policy (VENDOR-PARITY): newest public main (SDK v2 + skills) + public
# aap-skills. The exact vendor source commit (78e5738) is non-public, so we pin
# public main HEAD, which is the public SDK-v2 tree the vendor's build tracks.
#   - aap-mcp-server 174a0801 (2026-11-03, "#213 skills admin control") — SDK v2,
#     Express 5, loadSkills() from @modelcontextprotocol/server/ext/skills/node.
#   - aap-skills 1090eb3 (2026-11-06) — the SKILL.md packages + shared context/.
# The server reads skills from SKILLS_PATH (default /app/skills) + SHARED_CONTEXT_PATH
# (/app/context); skills_enabled defaults to FALSE upstream, so the Dockerfile sets
# SKILLS_ENABLED=true (we bundle them, matching the vendor 2.7 build).
#
# data/ (OpenAPI specs) + aap-mcp.sample.yaml live at the repo root (= the clone
# dir src/), so the Dockerfile's COPY src/data/ + COPY src/aap-mcp.sample.yaml are
# unchanged. Build flow (npm install + tsc, node >=22) is the same for SDK v2.
#
# Vendored-pin identification: read the runtime image's vcs-ref label (version +
# revision). CVE overrides must be re-audited for SDK v2 (express 5) after build.

MCP_SERVER_URL="https://github.com/ansible/aap-mcp-server"
MCP_SERVER_SHA="${MCP_SERVER_SHA:-174a08018c31b69279f1bfb2ed245ab57c86abd2}"

AAP_SKILLS_URL="https://github.com/ansible/aap-skills"
AAP_SKILLS_SHA="${AAP_SKILLS_SHA:-1090eb3e2fb649fa09dc301bd0fd9bf11c29d6bc}"

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

echo "==> Wiping ${SKILLS_DIR} and starting fresh"
rm -rf "$SKILLS_DIR"
echo "==> Cloning ${AAP_SKILLS_URL}"
git clone --quiet "$AAP_SKILLS_URL" "$SKILLS_DIR"
( cd "$SKILLS_DIR" && git checkout --quiet "$AAP_SKILLS_SHA" )

echo "==> Pinned versions:"
echo "    aap-mcp-server: $(cd "$SRC_DIR" && git log -1 --format='%h %ai - %s')"
echo "    aap-skills:     $(cd "$SKILLS_DIR" && git log -1 --format='%h %ai - %s')"
echo "    dumb-init:      $(cd "$DUMB_INIT_DIR" && git log -1 --format='%h - %s')"

# --- Drop out-of-scope services: galaxy (hub) + lightspeed (AI assistant) -----
# Both are out of scope for this rebuild — we ship no Automation Hub or Lightspeed
# backend, so surfacing their MCP tools (galaxy 36 + lightspeed 10) to clients only
# invites calls that 404. Disable the two services in the config (the loader skips
# disabled services before reading their spec), drop the now-empty content_discovery
# toolset (all its tools were galaxy/lightspeed), and remove the unused specs
# (lightspeed.json also carries vendor "Lightspeed" branding). Result: 579 -> 533
# tools; controller/gateway/eda unaffected; all 5 skills still load.
echo "==> Dropping galaxy + lightspeed services (out of scope)"
python3 - "$SRC_DIR/aap-mcp.sample.yaml" <<'PY'
import re, sys
f = sys.argv[1]
c = open(f).read()
for svc in ("galaxy", "lightspeed"):
    new, n = re.subn(r'(\n  - name: ' + svc + r'\n)', r'\1    enabled: false\n', c, count=1)
    assert n == 1, f"service '{svc}' not found in {f}"
    c = new
# remove the content_discovery toolset (its entries are all galaxy/lightspeed)
c, n = re.subn(r'\n  content_discovery:\n(?:    -[^\n]*\n)+', '\n', c, count=1)
assert n == 1, "content_discovery toolset block not found"
open(f, 'w').write(c)
print("    galaxy + lightspeed disabled; content_discovery removed")
PY
rm -f "$SRC_DIR/data/galaxy-openapi.json" "$SRC_DIR/data/lightspeed.json"
echo "    removed data/galaxy-openapi.json + data/lightspeed.json"

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
