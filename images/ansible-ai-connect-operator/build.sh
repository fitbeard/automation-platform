#!/usr/bin/env bash
#
# Build mcp-operator container image from public upstream code.
#
# Reproduces what ships in AAP 2.6-709 for the MCP server kind, but
# scoped to MCP-only: the upstream `ansible/ansible-ai-connect-operator`
# binary manages BOTH AnsibleAIConnect (chatbot/Lightspeed/Wisdom — RH/IBM
# enterprise stack we skip) AND AnsibleMCPConnect (MCP server, standalone).
# We deploy the whole binary; only AnsibleMCPConnect CRs ever get applied,
# so the chatbot/Lightspeed code paths never execute.
#
# Build steps:
#   1. git clone https://github.com/ansible/ansible-ai-connect-operator
#   2. git checkout 1e1d9cc3a8847b4530db7b7262beab446a85b2e6   (baseline)
#   3. (no cherry-picks — baseline already has full MCP capability)
#   4. (no local patches — operator stays upstream-pure)
#   5. snapshot only mcpconnect.ansible.com_*.yaml CRDs (skip aiconnect ones)
#   6. docker build
#
# Cherry-pick scope (deliberately empty):
#
#   Skipped (load-bearing — operator-sdk v1.40 upgrade chain):
#     4605077  Upgrade operator-sdk to v1.40.0 + remove kube-rbac-proxy
#     b87634c  Fix config/testing overlay to use new metrics patch
#     ff36c85  Merge of v1.40 PR
#     (Same load-bearing skip as awx/eda/gateway/awx-resource operators —
#      v1.40 base image dropped UBI, breaks our `dnf` step.)
#
#   Considered but skipped (pure chatbot/Lightspeed/Wisdom changes — irrelevant
#   for MCP-only deployment, listed for posterity):
#     d33e923  MCP sidecar ipv4/ipv6  (touches roles/chatbot/ only)
#     c66fba2  add mcp backup/restore (1100+ LOC, stateless service)
#     651ac91  initContainer securityContext guard  (chatbot-only)
#     651ac91, 3f9e647, 7dfd500, 22680ed, c5fd2f2, 0cbdb0e, 7768953,
#     d715f9c, b43ad4a, 9dcac84, d66e001, 514a55c, 2eb5954, 387cd74,
#     f65d277, 9d549db, 2c3edc5, a51a05c, dc2cbb8, d05bdad, e5ccd51,
#     7412f0a, d9b01f0, 744fb0b, 13dd54e, 92dfbef, 455a54c, ...
#     (All chatbot/Lightspeed/Wisdom/BYOK/RAG/llama-stack — net zero on MCP.)
#
#   Considered but no-op for MCP:
#     58c98e9 + 172adbc (ipv6 — `172adbc` reverts the mcpserver-side change
#     of `58c98e9`; net effect on roles/mcpserver/ is zero).
#
# Usage:
#   ./build.sh                          # Local build for host arch
#   ./build.sh --push                   # Multi-arch push to registry
#   ./build.sh --platform linux/arm64   # Single-arch local build
#   ./build.sh --prep-only              # Clone + checkout, skip docker
#   ./build.sh --no-cache               # Force docker rebuild from scratch
#
# Env overrides:
#   IMAGE_NAME=...       # default: quay.io/fitbeard/automation-platform/ansible-ai-connect-operator
#   IMAGE_TAG=...        # default: 2.6-709
#   BASELINE_COMMIT=...  # default: 1e1d9cc... (last commit before v1.40 upgrade)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"

# --- Upstream pin ------------------------------------------------------------

UPSTREAM_URL="https://github.com/ansible/ansible-ai-connect-operator"
BASELINE_COMMIT="${BASELINE_COMMIT:-1e1d9cc3a8847b4530db7b7262beab446a85b2e6}"

CHERRY_PICKS=()

# --- Flags -------------------------------------------------------------------

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
        -h|--help)    sed -n '2,75p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

VERSION="${VERSION:-2.6-709}"
IMAGE_NAME="${IMAGE_NAME:-quay.io/fitbeard/automation-platform/ansible-ai-connect-operator}"
IMAGE_TAG="${IMAGE_TAG:-$VERSION}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER_NAME="ap-operators-multiarch"

# --- Preflight ---------------------------------------------------------------

for cmd in git docker; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not in PATH" >&2; exit 1
    fi
done

# --- Always start fresh: wipe src/ and re-clone ------------------------------

echo "==> Wiping ${SRC_DIR} and starting fresh"
rm -rf "$SRC_DIR"

echo "==> Cloning ${UPSTREAM_URL}"
git clone --quiet "$UPSTREAM_URL" "$SRC_DIR"
cd "$SRC_DIR"

git config user.email "aap-rebuild-bot@localhost"
git config user.name  "AAP Rebuild"

echo "==> Checking out baseline ${BASELINE_COMMIT}"
git checkout --quiet "$BASELINE_COMMIT"

if [[ ${#CHERRY_PICKS[@]} -gt 0 ]]; then
    echo "==> Applying ${#CHERRY_PICKS[@]} upstream cherry-picks:"
    for sha in "${CHERRY_PICKS[@]}"; do
        short="$(git rev-parse --short=8 "$sha")"
        subject="$(git log --format='%s' -n 1 "$sha")"
        echo "    $short  $subject"
        git cherry-pick --allow-empty --keep-redundant-commits --quiet "$sha"
    done
else
    echo "==> No cherry-picks (baseline already has full MCP capability)"
fi

cd "$SCRIPT_DIR"

# --- Apply local patches on top of upstream ----------------------------------
if [[ -x "${SCRIPT_DIR}/patch.sh" ]]; then
    "${SCRIPT_DIR}/patch.sh"
fi

echo "==> src/ ready at $(cd "$SRC_DIR" && git rev-parse --short HEAD)"

# --- Snapshot CRDs to ./crds/ ------------------------------------------------
# Only mcpconnect.ansible.com_*.yaml — we deliberately skip aiconnect.ansible.com
# (Lightspeed/chatbot CRDs we never apply).
CRDS_OUT="${SCRIPT_DIR}/crds"
echo "==> Snapshotting MCP CRDs to $(realpath --relative-to="$PWD" "$CRDS_OUT" 2>/dev/null || echo "$CRDS_OUT")/"
rm -rf "$CRDS_OUT"
mkdir -p "$CRDS_OUT"
cp "${SRC_DIR}"/config/crd/bases/mcpconnect.ansible.com_*.yaml "$CRDS_OUT"/
echo "==> CRDs ($(ls "$CRDS_OUT" | wc -l | tr -d ' ')): $(ls "$CRDS_OUT" | tr '\n' ' ')"

# --- Build -------------------------------------------------------------------

if [[ $PREP_ONLY -eq 1 ]]; then
    echo "==> --prep-only: skipping docker build"
    exit 0
fi

echo "==> Building ${IMAGE_NAME}:${IMAGE_TAG}"

BUILD_ARGS=(
    --build-arg "OPERATOR_VERSION=${VERSION}"
    -t "${IMAGE_NAME}:${IMAGE_TAG}"
    -t "${IMAGE_NAME}:latest"
    -f "${SRC_DIR}/Dockerfile"
)

if [[ $PUSH -eq 1 ]]; then
    if ! docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
        docker buildx create --name "${BUILDER_NAME}" --driver docker-container --use
    else
        docker buildx use "${BUILDER_NAME}"
    fi
    docker buildx inspect --bootstrap >/dev/null
    echo "==> Multi-arch push: ${PLATFORMS}"
    docker buildx build --platform "${PLATFORMS}" --push ${NOC_ARG} "${BUILD_ARGS[@]}" "${SRC_DIR}"
else
    if [[ -n "$LOCAL_PLATFORM" ]]; then
        echo "==> Local build (platform=${LOCAL_PLATFORM})"
        docker buildx build --platform "${LOCAL_PLATFORM}" --load ${NOC_ARG} "${BUILD_ARGS[@]}" "${SRC_DIR}"
    else
        echo "==> Local build (host platform)"
        docker build ${NOC_ARG} "${BUILD_ARGS[@]}" "${SRC_DIR}"
    fi
    echo "==> Image: ${IMAGE_NAME}:${IMAGE_TAG}"
fi
