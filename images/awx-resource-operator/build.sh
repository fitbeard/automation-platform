#!/usr/bin/env bash
#
# Build awx-resource-operator + awx-resource-runner container images from
# public upstream code.
#
# Reproduces what ships in AAP 2.6-709 (platform-operator-bundle
# commit 73746606bcf6), using only transparent, publicly-verifiable
# operations:
#
#   1. git clone https://github.com/ansible/awx-resource-operator
#   2. git checkout 3de78b38ebb857f3f2a02aee4e15d26075eabdc7   (baseline)
#   3. apply patches/*.patch via git am --3way
#   4. docker build (operator) + docker build (runner)
#
# No binary blobs, no cached state — every run wipes src/ and re-does the
# clone + patch from scratch. Fully deterministic against upstream
# github.com/ansible/awx-resource-operator.
#
# Produces TWO **upstream-pure** images:
#   - Operator: quay.io/fitbeard/automation-platform/awx-resource-operator:2.6-709
#       Manages CRDs in tower.ansible.com/v1alpha1:
#         AnsibleJob, JobTemplate, AnsibleProject, AnsibleWorkflow,
#         AnsibleCredential, AnsibleSchedule, AnsibleInstanceGroup,
#         WorkflowTemplate, AnsibleInventory
#   - Runner:   quay.io/fitbeard/automation-platform/awx-resource-runner:2.6-709
#       Spawned per-CR by the operator as a batch/v1 Job to talk to AWX
#       via the awx.awx ansible collection.
#
# "downstreamify.sh" overlay (awx.awx -> ansible.controller
# collection swap) is NOT applied.
# tl;dr: ansible.controller is a private
# certified collection, not on public Galaxy — applying downstreamify
# would produce an image that fails to install collections without an
# AAP entitlement.
#
# Cherry-picks: NONE. The 709 bundle's awx-resource-operator subtree
# matches upstream@3de78b38 byte-for-byte after accounting for the
# downstreamify collection swap (which we skip) and Cachi2 packaging
# artefacts.
#
# Usage:
#   ./build.sh                          # Local build for host arch (both images)
#   ./build.sh --push                   # Multi-arch push to registry (both images)
#   ./build.sh --platform linux/arm64   # Single-arch local build (both images)
#   ./build.sh --prep-only              # Clone + patch, skip docker
#   ./build.sh --no-cache               # Force docker rebuild from scratch
#   ./build.sh --runner-only            # Skip operator image, build only runner
#   ./build.sh --operator-only          # Skip runner image, build only operator
#
# Env overrides:
#   IMAGE_NAME=...        # default: quay.io/fitbeard/automation-platform/awx-resource-operator
#   RUNNER_IMAGE_NAME=... # default: quay.io/fitbeard/automation-platform/awx-resource-runner
#   IMAGE_TAG=...         # default: 2.6-709
#   BASELINE_COMMIT=...   # default: 3de78b38...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"

# --- Upstream pin ------------------------------------------------------------

UPSTREAM_URL="https://github.com/ansible/awx-resource-operator"
BASELINE_COMMIT="${BASELINE_COMMIT:-3de78b38ebb857f3f2a02aee4e15d26075eabdc7}"

# No upstream cherry-picks — bundle == baseline + downstreamify (skipped)
# + Cachi2 packaging.
#
# Skipped between baseline and devel HEAD (deliberate):
#   a1671e2 — Upgrade operator-sdk to v1.40.0 + remove kube-rbac-proxy
#             *** load-bearing skip *** (same as awx-operator + eda-server-operator)
#   ee395ea — Merge of PR #186 (the v1.40 upgrade above)
#   7af5840 — Fix config/testing overlay to use new metrics patch (post-v1.40)
#   3f44333 — Standardize dev workflow Makefile (cosmetic; not COPYed into image)
CHERRY_PICKS=()

# --- Flags -------------------------------------------------------------------

PUSH=0
PREP_ONLY=0
LOCAL_PLATFORM=""
NOC_ARG=""
BUILD_OPERATOR=1
BUILD_RUNNER=1

for arg in "$@"; do
    case "$arg" in
        --push)          PUSH=1 ;;
        --no-cache)      NOC_ARG="--no-cache" ;;
        --prep-only)     PREP_ONLY=1 ;;
        --runner-only)   BUILD_OPERATOR=0 ;;
        --operator-only) BUILD_RUNNER=0 ;;
        --platform)      shift; LOCAL_PLATFORM="$1"; shift ;;
        --platform=*)    LOCAL_PLATFORM="${arg#*=}" ;;
        -h|--help)       sed -n '2,50p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

VERSION="${VERSION:-2.6-709}"
IMAGE_NAME="${IMAGE_NAME:-quay.io/fitbeard/automation-platform/awx-resource-operator}"
RUNNER_IMAGE_NAME="${RUNNER_IMAGE_NAME:-quay.io/fitbeard/automation-platform/awx-resource-runner}"
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
    echo "==> No cherry-picks (bundle matches baseline byte-for-byte after downstreamify-skip)"
fi

cd "$SCRIPT_DIR"

# --- Apply local patches on top of upstream ----------------------------------
if [[ -x "${SCRIPT_DIR}/patch.sh" ]]; then
    "${SCRIPT_DIR}/patch.sh"
fi

echo "==> src/ ready at $(cd "$SRC_DIR" && git rev-parse --short HEAD)"

# --- Snapshot CRDs to ./crds/ ------------------------------------------------
CRDS_OUT="${SCRIPT_DIR}/crds"
echo "==> Snapshotting CRDs to $(realpath --relative-to="$PWD" "$CRDS_OUT" 2>/dev/null || echo "$CRDS_OUT")/"
rm -rf "$CRDS_OUT"
mkdir -p "$CRDS_OUT"
cp "${SRC_DIR}"/config/crd/bases/tower.ansible.com_*.yaml "$CRDS_OUT"/
echo "==> CRDs ($(ls "$CRDS_OUT" | wc -l | tr -d ' ')): $(ls "$CRDS_OUT" | tr '\n' ' ')"

# --- Build -------------------------------------------------------------------

if [[ $PREP_ONLY -eq 1 ]]; then
    echo "==> --prep-only: skipping docker build"
    exit 0
fi

build_image() {
    local image="$1" tag="$2" dockerfile="$3" desc="$4"
    echo "==> Building $desc: ${image}:${tag}"

    local build_args=(
        -t "${image}:${tag}"
        -t "${image}:latest"
        -f "${dockerfile}"
    )

    if [[ $PUSH -eq 1 ]]; then
        if ! docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
            docker buildx create --name "${BUILDER_NAME}" --driver docker-container --use
        else
            docker buildx use "${BUILDER_NAME}"
        fi
        docker buildx inspect --bootstrap >/dev/null
        echo "==> Multi-arch push: ${PLATFORMS}"
        docker buildx build --platform "${PLATFORMS}" --push ${NOC_ARG} "${build_args[@]}" "${SRC_DIR}"
    else
        if [[ -n "$LOCAL_PLATFORM" ]]; then
            echo "==> Local build (platform=${LOCAL_PLATFORM})"
            docker buildx build --platform "${LOCAL_PLATFORM}" --load ${NOC_ARG} "${build_args[@]}" "${SRC_DIR}"
        else
            echo "==> Local build (host platform)"
            docker build ${NOC_ARG} "${build_args[@]}" "${SRC_DIR}"
        fi
        echo "==> Image: ${image}:${tag}"
    fi
}

if [[ $BUILD_OPERATOR -eq 1 ]]; then
    build_image "${IMAGE_NAME}" "${IMAGE_TAG}" "${SRC_DIR}/Dockerfile" "operator"
fi

if [[ $BUILD_RUNNER -eq 1 ]]; then
    build_image "${RUNNER_IMAGE_NAME}" "${IMAGE_TAG}" "${SRC_DIR}/Dockerfile.runner" "runner"
fi
