#!/usr/bin/env bash
#
# Build AWX Operator container image from public upstream code.
#
# Reproduces what ships in AAP 2.6-709 (platform-operator-bundle
# commit 6a4432fc9b69), using only transparent, publicly-verifiable
# operations:
#
#   1. git clone https://github.com/ansible/awx-operator
#   2. git checkout 7ead166ca030c2bebdd1c3254d152c9a2be7ee4d   (baseline)
#   3. git cherry-pick public upstream SHAs that carried on top
#      (see CHERRY_PICKS below)
#   4. docker build
#
# No binary blobs, no patch files, no cached state — every run wipes src/
# and re-does the clone + cherry-picks from scratch. Fully deterministic
# against upstream github.com/ansible/awx-operator.
#
# Usage:
#   ./build.sh                          # Local build for host arch
#   ./build.sh --push                   # Multi-arch push to registry
#   ./build.sh --platform linux/arm64   # Single-arch local build
#   ./build.sh --prep-only              # Clone + cherry-pick, skip docker
#   ./build.sh --no-cache               # Force docker rebuild from scratch
#
# Env overrides:
#   IMAGE_NAME=...       # default: quay.io/fitbeard/automation-platform/awx-operator
#   IMAGE_TAG=...        # default: 2.6-709
#   BASELINE_COMMIT=...  # default: 7ead166c...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"

# --- Upstream pin ------------------------------------------------------------

UPSTREAM_URL="https://github.com/ansible/awx-operator"
BASELINE_COMMIT="${BASELINE_COMMIT:-7ead166ca030c2bebdd1c3254d152c9a2be7ee4d}"

# Eight upstream SHAs cherry-picks on top of the baseline in
# AAP 2.6-709. Applied in chronological order. The two trailing picks
# (5697fee + 60fc7d8) are new in 2.6-709 vs 2.6-708.
#
# Skipped between picks (deliberate, preserved for both 708 and 709):
#   bfc4d8e — Add CRD validation for postgres_image+image_version pairing (#2096)
#   fcf9a08 — Remove OperatorHub automation/documentation
#   f9c05a5 — ci: Update DOCKER_API_VERSION to 1.44 (#2102)
#   c996c88 — Fix config/testing overlay to use new metrics patch
#   5fb6bb7 — Upgrade operator-sdk to v1.40.0 and remove kube-rbac-proxy  *** load-bearing skip ***
#   a47b06f — devel: Update development guide
#   605b46d — Collect logs with greater determination (#2087)
CHERRY_PICKS=(
    "eeed2b8ae5dd1956d2bf127c7c986fa53792553c"  # 2026-01-19 django: --no-imports (Django 5.2 compat)
    "f04ab1878cbbccd7bf0a959d50f29e89ce13b64b"  # 2026-01-23 web: python3.11 -> python3.12 mountPath
    "e0ce3ef71d5f76d1a5a1ecb12721f2484f10b16a"  # 2026-02-17 [AAP-64061] nginx log markers (#2100)
    "d4b295e8b4bb4a9233275edf576ea76e85bc2bc7"  # 2026-02-24 create_backup_pvc option (#2097)
    "0b4b5dd7fdabc221ce70fcb1228ab5bb2bd6b90e"  # 2026-02-27 AWXRestore force_drop_db
    "56f10cf9666a37ec385192176214a4f48e44127e"  # 2026-03-05 Fix custom backup_pvc name (#2105)
    "5697feea5705c45909b67acbd8539955963a4bd5"  # 2026-03-23 Fix unquoted timestamps in event templates (#2110)  [709]
    "60fc7d856c553fd16e91a06fdc5cee66798b2aa3"  # 2026-03-24 Add use_db_compression option (#2106)              [709]
)

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

VERSION="${VERSION:-2.6-709}"
DEFAULT_AWX_VERSION="${DEFAULT_AWX_VERSION:-25.0.0}"
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

echo "==> Applying ${#CHERRY_PICKS[@]} upstream cherry-picks:"
for sha in "${CHERRY_PICKS[@]}"; do
    short="$(git rev-parse --short=8 "$sha")"
    subject="$(git log --format='%s' -n 1 "$sha")"
    echo "    $short  $subject"
    git cherry-pick --allow-empty --keep-redundant-commits --quiet "$sha"
done

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
