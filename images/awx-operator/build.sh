#!/usr/bin/env bash
#
# Build AWX Operator container image from public upstream code.
#
# The controller operator ships as public ansible/awx-operator +
# downstreamify.sh (the AWX→AutomationController rename, which we deliberately
# do NOT apply — our operator stays upstream-pure and reconciles AWX CRs; the
# gateway operator's unpatch.sh handles the rename for the AAP-CR cascade).
# So we build straight from public upstream:
#
#   1. git clone https://github.com/ansible/awx-operator
#   2. git checkout <devel-HEAD>                      (baseline, see below)
#   3. (no cherry-picks — the 2.7 baseline already contains all of them)
#   4. apply our local patches (patches/) + pin the base image
#   5. docker build
#
# 2.7 baseline move: we jump from the 2.6 baseline 7ead166c (operator-sdk
# v1.36.1) to the current devel HEAD, which is already on operator-sdk v1.42.x
# with kube-rbac-proxy removed (commit 5fb6bb7) — the v1.40+ upgrade that the
# 2.6 build deliberately skipped (the v1.36.1 lock is lifted for 2.7). Base
# image = **v1.42.3** (the devel-HEAD Dockerfile's native base: ubi-minimal +
# microdnf, newest operator-sdk, no Dockerfile adaptation). We considered the
# 2.7 downstream's declared v1.40.0 but it is full-ubi/dnf and would need a
# microdnf->dnf swap — v1.42.3 is cleaner and newer.
#
# Usage:
#   ./build.sh                          # Local build for host arch
#   ./build.sh --push                   # Multi-arch push to registry
#   ./build.sh --platform linux/arm64   # Single-arch local build
#   ./build.sh --prep-only              # Clone + patch, skip docker
#   ./build.sh --no-cache               # Force docker rebuild from scratch
#
# Env overrides:
#   IMAGE_NAME=...       # default: quay.io/fitbeard/automation-platform/awx-operator
#   BASELINE_COMMIT=...  # default: devel HEAD pin below
#   BASE_IMAGE_TAG=...   # default: v1.40.0 (ansible-operator base image)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"

# --- Upstream pin ------------------------------------------------------------

UPSTREAM_URL="https://github.com/ansible/awx-operator"
# devel HEAD at the cut (2026-11-19, "[AAP-95285] use
# operator_sdk.util.k8s_event for failure events" #2146). Contains the full
# v1.40+ migration (5fb6bb7) + all 17 commits the 2.6 build cherry-picked +
# the NetworkPolicy/metrics-utility/backup-label fixes 2.6 skipped (all are
# in the 2.7 era). Bump this pin as upstream advances.
BASELINE_COMMIT="${BASELINE_COMMIT:-023470e}"

# ansible-operator base image pinned into the upstream Dockerfile's FROM.
# v1.42.3 is the native base for the devel-HEAD Dockerfile (ubi-minimal +
# microdnf + the `microdnf install openssl` step) — the newest operator-sdk and
# no Dockerfile adaptation needed. (v1.40.0, the 2.7 downstream controller-op's
# declared base, is full ubi with dnf/openssl and would need a microdnf->dnf
# swap — handled below if ever pinned, but v1.42.3 is cleaner, so we use it.)
BASE_IMAGE_TAG="${BASE_IMAGE_TAG:-v1.42.3}"

# No cherry-picks for 2.7. The 2.6 build carried 17 picks on top of the old
# v1.36.1 baseline (7ead166c); ALL 17 are ancestors of the 2.7 devel-HEAD
# baseline above, as are the NetworkPolicy/metrics-utility/receptor/backup-label
# commits 2.6 deliberately skipped (they belong to the 2.7 era). So the baseline
# jump subsumes the entire pick list — nothing to re-apply.
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
        -h|--help)    sed -n '2,35p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

VERSION="${VERSION:-2.7-1794591068.0}"
DEFAULT_AWX_VERSION="${DEFAULT_AWX_VERSION:-27.0.0}"
IMAGE_NAME="${IMAGE_NAME:-quay.io/fitbeard/automation-platform/awx-operator}"
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

# Identity required for cherry-pick to create commit objects
git config user.email "aap-rebuild-bot@localhost"
git config user.name  "AAP Rebuild"

echo "==> Checking out baseline ${BASELINE_COMMIT}"
git checkout --quiet "$BASELINE_COMMIT"

echo "==> Applying ${#CHERRY_PICKS[@]} upstream cherry-picks"
for sha in ${CHERRY_PICKS[@]+"${CHERRY_PICKS[@]}"}; do
    short="$(git rev-parse --short=8 "$sha")"
    subject="$(git log --format='%s' -n 1 "$sha")"
    echo "    $short  $subject"
    git cherry-pick --allow-empty --keep-redundant-commits --quiet "$sha"
done

# Pin the ansible-operator base image to the user-chosen tag (upstream HEAD
# defaults to v1.42.3; the 2.7 downstream controller-operator runs on v1.40.0).
# The two bases differ: v1.42.3 is ubi-minimal (microdnf, no openssl — hence the
# upstream `microdnf install openssl` step); v1.40.0 is full ubi (dnf, openssl
# already present). So when pinning a dnf-based tag we also swap the Dockerfile's
# `microdnf` calls to `dnf` (which exists there), keeping the security-update +
# openssl intent without failing on the missing microdnf.
echo "==> Pinning base image: ansible-operator:${BASE_IMAGE_TAG}"
sedi() { if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi; }
sedi -E "s|(operator-framework/ansible-operator):v[0-9]+\.[0-9]+\.[0-9]+|\1:${BASE_IMAGE_TAG}|" "${SRC_DIR}/Dockerfile"
if [[ "${BASE_IMAGE_TAG}" == "v1.40.0" ]]; then
    sedi 's/microdnf/dnf/g' "${SRC_DIR}/Dockerfile"
fi
grep -m1 '^FROM' "${SRC_DIR}/Dockerfile" | sed 's/^/    /'

cd "$SCRIPT_DIR"

# --- Apply local patches on top of upstream cherry-picks ---------------------
# patch.sh applies any patches/*.patch via `git am --3way`, producing real
# commits in src/. Fails loudly on upstream drift instead of silent sed.
if [[ -x "${SCRIPT_DIR}/patch.sh" ]]; then
    "${SCRIPT_DIR}/patch.sh"
fi

echo "==> src/ ready at $(cd "$SRC_DIR" && git rev-parse --short HEAD)"

# --- Snapshot CRDs to awx-operator/crds/ -------------------------------
# Copies the post-patch CRDs from src/config/crd/bases/ into ./crds/ so they
# can be tracked in git (diffs surface upstream additions on rebuild) and
# applied directly via `kubectl apply -f awx-operator/crds/`.
CRDS_OUT="${SCRIPT_DIR}/crds"
echo "==> Snapshotting CRDs to $(realpath --relative-to="$PWD" "$CRDS_OUT" 2>/dev/null || echo "$CRDS_OUT")/"
rm -rf "$CRDS_OUT"
mkdir -p "$CRDS_OUT"
cp "${SRC_DIR}"/config/crd/bases/awx.ansible.com_*.yaml "$CRDS_OUT"/
echo "==> CRDs ($(ls "$CRDS_OUT" | wc -l | tr -d ' ')): $(ls "$CRDS_OUT" | tr '\n' ' ')"

# --- Build -------------------------------------------------------------------

if [[ $PREP_ONLY -eq 1 ]]; then
    echo "==> --prep-only: skipping docker build"
    exit 0
fi

echo "==> Building ${IMAGE_NAME}:${IMAGE_TAG}"

BUILD_ARGS=(
    --build-arg "OPERATOR_VERSION=${VERSION}"
    --build-arg "DEFAULT_AWX_VERSION=${DEFAULT_AWX_VERSION}"
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
