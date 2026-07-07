#!/usr/bin/env bash
#
# Build the AAP Gateway Operator container image — bundle-extraction edition.
#
# Unlike build-operator-{awx,eda}/, the gateway-operator has NO public
# upstream Git repo. Source ships only inside source-bundle
# OCI image:
#
#   registry.redhat.io/ansible-automation-platform/platform-operator-bundle:2.6-709-source
#
# Step 1 (this script's first phase) pulls the bundle, locates the source
# layer, and extracts the gateway-operator subtree into ./src/.
#
# AUTHENTICATION
# --------------
# The source bundle lives in the vendor's registry, which requires an
# account or a registry service-account token. One-time setup — log in to
# the registry host shown in the BUNDLE_IMAGE path above:
#
#   docker login <registry host>
#   Username: <account username, or registry service-account name>
#   Password: <account password, or service-account token>
#
# Service-account tokens are recommended for non-interactive use; consult
# the vendor's registry-authentication documentation for the details.
#
# Once `docker login` has stored credentials this script picks them up
# automatically.
#
# Usage:
#   ./build.sh                       # pull bundle (if absent) + extract + unpatch + git-am patches + CRD snapshot + docker build
#   ./build.sh --re-extract          # force re-pull + re-extract (wipes src/)
#   ./build.sh --prep-only           # everything except the docker build (handy for inspecting src/ + crds/)
#   ./build.sh --no-cache            # skip docker layer cache (full rebuild from FROM)
#   ./build.sh --push                # multi-arch buildx + push to registry (requires `docker buildx create`)
#   ./build.sh --platform <p>        # single-arch local build (e.g. linux/arm64)
#   Flags compose: ./build.sh --re-extract --no-cache  forces full re-pull + cacheless rebuild.

set -euo pipefail

# --- Configuration -----------------------------------------------------------

BUNDLE_IMAGE="${BUNDLE_IMAGE:-registry.redhat.io/ansible-automation-platform/platform-operator-bundle:2.6-709-source}"
REGISTRY_HOST="${BUNDLE_IMAGE%%/*}"   # login target, derived from the image path
SUBPROJECT="${SUBPROJECT:-gateway-operator}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"

RE_EXTRACT=0
PREP_ONLY=0
PUSH=0
LOCAL_PLATFORM=""
NOC_ARG=""
for arg in "$@"; do
    case "$arg" in
        --re-extract) RE_EXTRACT=1 ;;
        --prep-only)  PREP_ONLY=1 ;;
        --push)       PUSH=1 ;;
        --no-cache)   NOC_ARG="--no-cache" ;;
        --platform)   shift; LOCAL_PLATFORM="$1"; shift ;;
        --platform=*) LOCAL_PLATFORM="${arg#*=}" ;;
        -h|--help)    sed -n '2,42p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

VERSION="${VERSION:-2.6-709}"
IMAGE_NAME="${IMAGE_NAME:-quay.io/your-namespace/ap-gateway-operator}"
IMAGE_TAG="${IMAGE_TAG:-$VERSION}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER_NAME="aap-operators-multiarch"

# --- Preflight ---------------------------------------------------------------

for cmd in docker tar; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not in PATH" >&2; exit 1
    fi
done

# --- Phase 1: pull the source bundle (idempotent) ----------------------------

if ! docker image inspect "$BUNDLE_IMAGE" >/dev/null 2>&1; then
    echo "==> Pulling $BUNDLE_IMAGE"
    echo "    Authentication required: docker login ${REGISTRY_HOST}"
    if ! docker pull "$BUNDLE_IMAGE"; then
        cat >&2 <<EOF

ERROR: docker pull failed.

If you see "unauthorized" or "authentication required":
  1. docker login ${REGISTRY_HOST}
  2. Use your vendor account credentials, or a registry
     service-account token
  3. Re-run this script.

EOF
        exit 1
    fi
else
    echo "==> Bundle already present locally: $BUNDLE_IMAGE"
fi

# --- Phase 2: extract gateway-operator/ from the source bundle ---------------

if [[ -d "$SRC_DIR" && $RE_EXTRACT -eq 0 ]]; then
    echo "==> src/ already populated — skipping extraction (pass --re-extract to refresh)"
    echo "    src/ contains $(find "$SRC_DIR" -type f | wc -l | tr -d ' ') files"
    SKIP_EXTRACT=1
else
    SKIP_EXTRACT=0
fi

if [[ $SKIP_EXTRACT -eq 0 ]]; then

WORK_DIR="$(mktemp -d -t aap-bundle-XXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Saving bundle image to a tarball (working dir: $WORK_DIR)"
docker save "$BUNDLE_IMAGE" -o "$WORK_DIR/bundle.tar"

echo "==> Unpacking image tarball"
tar -xf "$WORK_DIR/bundle.tar" -C "$WORK_DIR"

# Bundle is a Build-Source-Image (BSI):
#   outer layers contain `extra_src_dir/extra-src-<sha>.tar`
#   that inner tar contains either:
#     - go-module dependency caches (large, ~150 MB) — NOT what we want
#     - `ansible-automation-platform-operator-bundle-container-<sha>.tar.gz`
#       which expands to a directory containing every sub-operator's
#       source tree (this is what we want)
echo "==> Locating the source layer (BSI extra_src_dir with operator-bundle tarball)"
SOURCE_LAYER=""
for blob in "$WORK_DIR"/blobs/sha256/*; do
    [[ -f "$blob" ]] || continue
    # Layer must contain ./extra_src_dir/extra-src-*.tar at top-level
    tar -tzf "$blob" 2>/dev/null | grep -q '^\./extra_src_dir/extra-src-.*\.tar$' || continue
    # Inner tarball must reference an operator-bundle source archive
    if tar -xzOf "$blob" 2>/dev/null | tar -t 2>/dev/null | grep -q 'ansible-automation-platform-operator-bundle-container-.*\.tar\.gz$'; then
        SOURCE_LAYER="$blob"
        echo "    found: $(basename "$blob") ($(du -h "$blob" | cut -f1))"
        break
    fi
done

if [[ -z "$SOURCE_LAYER" ]]; then
    echo "ERROR: could not find a layer containing the operator-bundle source archive" >&2
    exit 1
fi

echo "==> Unpacking source layer"
EXTRACT_DIR="$WORK_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$SOURCE_LAYER" -C "$EXTRACT_DIR"

INNER_TAR=("$EXTRACT_DIR"/extra_src_dir/extra-src-*.tar)
[[ -f "${INNER_TAR[0]}" ]] || { echo "ERROR: extra-src-*.tar missing" >&2; exit 1; }

echo "==> Unpacking BSI inner tar"
tar -xf "${INNER_TAR[0]}" -C "$EXTRACT_DIR"

OPERATOR_BUNDLE_TGZ=("$EXTRACT_DIR"/ansible-automation-platform-operator-bundle-container-*.tar.gz)
[[ -f "${OPERATOR_BUNDLE_TGZ[0]}" ]] || { echo "ERROR: operator-bundle tarball missing" >&2; exit 1; }

echo "==> Unpacking operator-bundle tarball"
tar -xzf "${OPERATOR_BUNDLE_TGZ[0]}" -C "$EXTRACT_DIR"

BUNDLE_ROOT=$(find "$EXTRACT_DIR" -maxdepth 2 -type d -name 'ansible-automation-platform-operator-bundle-container-*' | head -1)
[[ -d "$BUNDLE_ROOT" ]] || { echo "ERROR: bundle root directory not found" >&2; exit 1; }

if [[ ! -d "${BUNDLE_ROOT}/${SUBPROJECT}" ]]; then
    echo "ERROR: ${SUBPROJECT}/ not found inside bundle. Available subprojects:" >&2
    ls "$BUNDLE_ROOT" >&2
    exit 1
fi

# --- Phase 3: copy to src/ ---------------------------------------------------

echo "==> Copying ${SUBPROJECT}/ to $(realpath --relative-to="$PWD" "$SRC_DIR" 2>/dev/null || echo "$SRC_DIR")/"
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
cp -R "${BUNDLE_ROOT}/${SUBPROJECT}/." "$SRC_DIR/"

echo "==> src/ ready ($(find "$SRC_DIR" -type f | wc -l | tr -d ' ') files)"

fi  # end if [[ $SKIP_EXTRACT -eq 0 ]]

# --- Phase 4: inverse-downstreamify (sed-based bulk renames) ----------------
# unpatch.sh undoes select downstreamify transformations so the
# gateway-operator can drive vanilla upstream sub-operators (AWX, EDA, ...).
if [[ -x "${SCRIPT_DIR}/unpatch.sh" ]]; then
    "${SCRIPT_DIR}/unpatch.sh"
fi

# --- Phase 5: git-init src/ for patch.sh -----------------------------------
# `git am` needs a git repo. Bundle source is a tarball — no git history.
# Init and commit the post-unpatch state as the baseline, so patches in
# patches/ apply against a clean tree.
if [[ -x "${SCRIPT_DIR}/patch.sh" ]] && [[ ! -d "${SRC_DIR}/.git" ]]; then
    (cd "$SRC_DIR" && \
        git init --quiet && \
        git config user.email "aap-rebuild-bot@localhost" && \
        git config user.name  "AAP Rebuild" && \
        git add -A && \
        git commit --quiet -m "baseline: bundle source post-unpatch")
fi

# --- Phase 6: patch.sh — surgical patches via git am -----------------------
# Context-sensitive diffs (multi-file edits, real bug fixes, behavior tweaks
# beyond simple renames). See patches/*.patch for what's applied.
if [[ -x "${SCRIPT_DIR}/patch.sh" ]]; then
    "${SCRIPT_DIR}/patch.sh"
fi

# --- Phase 7: snapshot CRDs to ap-gateway-operator/crds/ ------------------
# Copies the CRDs from src/config/crd/bases/ into ./crds/ so they can be
# tracked in git (diffs surface upstream additions on rebuild) and applied
# directly via `kubectl apply -f ap-gateway-operator/crds/`.
CRDS_OUT="${SCRIPT_DIR}/crds"
echo "==> Snapshotting CRDs to $(realpath --relative-to="$PWD" "$CRDS_OUT" 2>/dev/null || echo "$CRDS_OUT")/"
rm -rf "$CRDS_OUT"
mkdir -p "$CRDS_OUT"
cp "${SRC_DIR}"/config/crd/bases/aap.ansible.com_*.yaml "$CRDS_OUT"/
echo "==> CRDs ($(ls "$CRDS_OUT" | wc -l | tr -d ' ')): $(ls "$CRDS_OUT" | tr '\n' ' ')"

# --- Build -------------------------------------------------------------------

if [[ $PREP_ONLY -eq 1 ]]; then
    echo "==> --prep-only: skipping docker build"
    exit 0
fi

# --- Phase 8: docker build ---------------------------------------------------

echo "==> Building ${IMAGE_NAME}:${IMAGE_TAG}"

BUILD_ARGS=(
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
