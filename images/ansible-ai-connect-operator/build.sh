#!/usr/bin/env bash
#
# Build mcp-operator container image from public upstream code.
#
# Reproduces the MCP server kind from platform-operator-bundle:2.6-1787258025,
# scoped to MCP-only: the upstream `ansible/ansible-ai-connect-operator`
# binary manages BOTH AnsibleAIConnect (chatbot/Lightspeed/Wisdom — the
# vendor's enterprise stack we skip) AND AnsibleMCPConnect (MCP server, standalone).
# We deploy the whole binary; only AnsibleMCPConnect CRs ever get applied,
# so the chatbot/Lightspeed code paths never execute.
#
# REFRESH POLICY —  (2026-11): build from public main HEAD. In 2.6 this was
# the ONE operator pinned pre-v1.40 (baseline 1e1d9cc3) because our base-image lock
# was ansible-operator v1.36.1. For 2.7 v1.40+ is accepted (awx/eda/gateway build on
# v1.40.0/v1.42.3), so public main's v1.42.3-native tree is usable directly — no
# more "minimal/not-reconstructable" workaround, no cherry-picks. Public main is
# upstream-pure mcpconnect.ansible.com/AnsibleMCPConnect (we keep that; the 2.7
# downstream mcpserver rename is NOT applied — our gateway-op cascade uses mcpconnect
# too). The 2.6 patches are superseded: the 2.7 patches/0001 (MCP-only watches.yaml)
# subsumes the old 0001 (drop chatbot watch); 0002 (enableServiceLinks) is now upstream.
#
# Build steps:
#   1. git clone https://github.com/ansible/ansible-ai-connect-operator
#   2. git checkout <public main HEAD>   (v1.42.3-native)
#   3. (no cherry-picks)
#   4. patch.sh — apply patches/*.patch via git am (0001 = MCP-only watches.yaml)
#   5. snapshot only mcpconnect.ansible.com_ansiblemcpconnects.yaml
#   6. docker build (Dockerfile FROM ansible-operator:v1.42.3, native — no base swap)
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
#   IMAGE_TAG=...        # default: 2.6-1787258025
#   BASELINE_COMMIT=...  # default: 1e1d9cc... (last commit before v1.40 upgrade)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"

# --- Upstream pin ------------------------------------------------------------

UPSTREAM_URL="https://github.com/ansible/ansible-ai-connect-operator"
# Moved OFF the old pre-v1.40 baseline (1e1d9cc3) to public main HEAD.
# Now that ansible-operator v1.40+ is accepted (awx/eda/gateway all build on
# v1.40.0/v1.42.3), public main's v1.42.3-native structure is usable directly —
# this was the ONE operator stuck pre-v1.40 in 2.6. Public main stays upstream-pure
# `mcpconnect.ansible.com/AnsibleMCPConnect` (matches our gateway-op cascade, which
# inverts the 2.7 downstream `mcpserver` rename via unpatch.sh), so NO downstreamify.
BASELINE_COMMIT="${BASELINE_COMMIT:-d65c414489567b9559d968add538b4c52c94b9e8}"

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

VERSION="${VERSION:-2.7-1794591068.0}"
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

# --- Apply our patches via git am (patch.sh) ---------------------------------
# Source deltas to the operator's ansible tree live in patches/ as git-format-patch
# mailbox files, applied by patch.sh with `git am --3way`. Same transparent,
# drift-surfacing workflow as the other operators — each patch becomes a reviewable
# commit in src/'s git log, and upstream drift fails loudly at `git am` instead of
# being silently skipped. Currently:
#   0001  MCP-only watches.yaml (drop Lightspeed + MCP backup/restore watches)
# (Supersedes the 2.6 git-am 0001 drop-chatbot-watch + 0002 enableServiceLinks.)
if [[ -x "${SCRIPT_DIR}/patch.sh" ]]; then
    "${SCRIPT_DIR}/patch.sh"
fi

echo "==> src/ ready at $(cd "$SRC_DIR" && git rev-parse --short HEAD)"

# --- Snapshot CRDs to ./crds/ ------------------------------------------------
# Only the AnsibleMCPConnect CRD — we skip aiconnect.ansible.com (Lightspeed) and
# the new AnsibleMCPConnectBackup/Restore CRDs (we deploy only the MCP server, and
# watches.yaml above drops their watches).
CRDS_OUT="${SCRIPT_DIR}/crds"
echo "==> Snapshotting MCP CRD to $(realpath --relative-to="$PWD" "$CRDS_OUT" 2>/dev/null || echo "$CRDS_OUT")/"
rm -rf "$CRDS_OUT"
mkdir -p "$CRDS_OUT"
cp "${SRC_DIR}"/config/crd/bases/mcpconnect.ansible.com_ansiblemcpconnects.yaml "$CRDS_OUT"/
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
