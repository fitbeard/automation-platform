#!/usr/bin/env bash
#
# Build the AAP Gateway Operator container image — bundle-extraction edition.
#
# Unlike build-operator-{awx,eda}/, the gateway-operator has NO public
# upstream Git repo. Source ships only inside source-bundle
# OCI image:
#
#   registry.redhat.io/ansible-automation-platform/platform-operator-bundle:2.6-1794615097-source
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"

# The gateway operator ships as its own per-component "-source" BSI OCI
# (aap-gateway-operator wrapper) — simpler than the 2.6 platform-operator-bundle
# nested extraction. Still NO public upstream + NO license, so (as 2.6) we extract
# the -source, unpatch the downstream renames, apply our patches, and gitignore
# the verbatim CRDs. Pull it locally first (registry.redhat.io auth).
# shellcheck source=extract-source-oci.sh
. "${SCRIPT_DIR}/extract-source-oci.sh"
GATEWAY_OP_SOURCE_IMAGE="${GATEWAY_OP_SOURCE_IMAGE:-registry.redhat.io/ansible-automation-platform-27/gateway-rhel9-operator:2.7-1794275922-source}"
GATEWAY_OP_SUBPATH="aap-gateway-operator"
REGISTRY_HOST="${GATEWAY_OP_SOURCE_IMAGE%%/*}"
GATEWAY_OP_EXTRACT_DIR="${SCRIPT_DIR}/.src-extract"
# ansible-operator base image. Unlike awx/eda (whose devel-HEAD Dockerfiles are
# v1.42.3-native = ubi-minimal + microdnf), the gateway-op -source Dockerfile is
# written for v1.40.0 = full-ubi + **dnf** (it `dnf install`s python3.12-psycopg2).
# So we keep its NATIVE v1.40.0 — pinning v1.42.3 (microdnf, no dnf) breaks the
# build (exit 127). Native base per source = no pkg-manager swap.
BASE_IMAGE_TAG="${BASE_IMAGE_TAG:-v1.40.0}"

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

VERSION="${VERSION:-2.7-1794591068.0}"
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

# --- Phase 1+2+3: extract aap-gateway-operator/ from the per-component -source

if [[ -d "$SRC_DIR" && $RE_EXTRACT -eq 0 ]]; then
    echo "==> src/ already populated — skipping extraction (pass --re-extract to refresh)"
    echo "    src/ contains $(find "$SRC_DIR" -type f | wc -l | tr -d ' ') files"
else
    echo "==> Extracting ${GATEWAY_OP_SUBPATH}/ from ${GATEWAY_OP_SOURCE_IMAGE##*/}"
    if ! docker image inspect "$GATEWAY_OP_SOURCE_IMAGE" >/dev/null 2>&1; then
        echo "    Not present locally — pull it first: docker login ${REGISTRY_HOST} && docker pull ${GATEWAY_OP_SOURCE_IMAGE}" >&2
        exit 1
    fi
    GW_OP_WRAPPER=$(extract_source_oci "$GATEWAY_OP_SOURCE_IMAGE" "$GATEWAY_OP_EXTRACT_DIR")
    GW_OP_SRC="${GW_OP_WRAPPER}/${GATEWAY_OP_SUBPATH}"
    [[ -d "${GW_OP_SRC}/roles" ]] || { echo "ERROR: ${GATEWAY_OP_SUBPATH}/ not found in the -source image" >&2; exit 1; }
    rm -rf "$SRC_DIR"; mkdir -p "$SRC_DIR"
    cp -a "${GW_OP_SRC}/." "$SRC_DIR/"
    # Pin the ansible-operator base image (the -source Dockerfile uses v1.40.0).
    if sed --version >/dev/null 2>&1; then SEDI=(sed -i); else SEDI=(sed -i ''); fi
    "${SEDI[@]}" -E "s|(operator-framework/ansible-operator):v[0-9]+\.[0-9]+\.[0-9]+|\1:${BASE_IMAGE_TAG}|" "${SRC_DIR}/Dockerfile"
    echo "==> src/ ready ($(find "$SRC_DIR" -type f | wc -l | tr -d ' ') files); base $(grep -m1 '^FROM' "${SRC_DIR}/Dockerfile" | awk '{print $2}')"
fi

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
