#!/usr/bin/env bash
#
# Build EDA Server Operator container image from public upstream code.
#
# Reproduces what ships in AAP 2.6-709 (platform-operator-bundle
# commit b72dbf054980), using only transparent, publicly-verifiable
# operations:
#
#   1. git clone https://github.com/ansible/eda-server-operator
#   2. git checkout b72dbf05498050209cf1ba799af3f0bd2d896d61   (baseline)
#   3. git cherry-pick 2 public upstream SHAs that carried on top
#      (see CHERRY_PICKS below)
#   4. patch.sh applies our local patches (postgres tuning)
#   5. docker build
#
# No binary blobs, no cached state — every run wipes src/ and re-does the
# clone + cherry-picks + patches from scratch.
#
# Produces an upstream-pure operator:
#   - Kind:    EDA / EDABackup / EDARestore
#   - Group:   eda.ansible.com
#   - Image:   quay.io/fitbeard/automation-platform/eda-server-operator:2.6-709
#
# downstreamify.sh overlay (RELATED_IMAGE_EDA* injection,
# Route ingress default, /var/lib/ansible-automation-platform/eda
# path swaps, FQDN k8s rewrites) is NOT applied.
#
# Usage:
#   ./build.sh                          # Local build for host arch
#   ./build.sh --push                   # Multi-arch push to registry
#   ./build.sh --platform linux/arm64   # Single-arch local build
#   ./build.sh --prep-only              # Clone + cherry-pick + patch, skip docker
#   ./build.sh --no-cache               # Force docker rebuild from scratch
#
# Env overrides:
#   IMAGE_NAME=...       # default: quay.io/fitbeard/automation-platform/eda-server-operator
#   IMAGE_TAG=...        # default: 2.6-709
#   BASELINE_COMMIT=...  # default: b72dbf05...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"

# --- Upstream pin ------------------------------------------------------------

UPSTREAM_URL="https://github.com/ansible/eda-server-operator"
BASELINE_COMMIT="${BASELINE_COMMIT:-b72dbf05498050209cf1ba799af3f0bd2d896d61}"

# Upstream SHAs cherry-picks on top of the baseline in AAP 2.6-709
# (was 2 picks for 708, +5 new for 709). Applied in chronological order.
# Identified by replaying baseline + downstreamify on a fresh checkout and
# diffing against the bundle source.
#
# Skipped between picks (deliberate, preserved across both 708 and 709):
#   b7e4168 — Merge operator-sdk-v1.40.0-upgrade (#323)  *** load-bearing skip ***
#   4c9fd0c — cleanup old redis artifacts (#321) — REVERTED by f939b71 (round-trip)
#   f939b71 — Revert "cleanup old redis artifacts"
#   6d43ede — Revert "Remove redis from operator (#328)"
#   6a5cbe0 — event streams DB user feature (#326) — hasn't picked
#   1812547 — event persistence feature (#332) — hasn't picked
#   cd7ef68 — Merge fix_awx_restore (#322)
#   eac9f69 — Merge AAP-67753
CHERRY_PICKS=(
    "4cd8202304a1904010f625892cc8d943e88dee86"  # 2026-02-03 create_backup_pvc option (#316)               [708]
    "6bf7694465ae8ea72fead93219c62387c50115f5"  # 2026-03-04 backup_pvc custom name in templates (#324)     [708]
    "0f094114d8e24eb2f607073aaabc1b5a19d75414"  # 2026-03-23 Fix unquoted timestamps in event templates    [709]
    "a64e5b10e4c043bdbe199ed4a319e1720ca13708"  # 2026-03-24 Add use_db_compression option (#325)          [709]
    "8fd2fa2cfb7185d1dbe2a1a1f22a08f326cca072"  # 2026-04-01 Add --no-imports to django commands           [709]
    "ccccc992f8417eb137784ff87796c42b535b6a75"  # 2026-04-09 Fix dup Jinja2 close tag (activation-worker)  [709]
    "5183504188245f833d817b0eb8140ee1439bdb9c"  # 2026-04-09 Fix dup Jinja2 close tags (other 2 templates) [709]
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
DEFAULT_EDA_VERSION="${DEFAULT_EDA_VERSION:-1.2.8}"
DEFAULT_EDA_UI_VERSION="${DEFAULT_EDA_UI_VERSION:-2.6.8}"
IMAGE_NAME="${IMAGE_NAME:-quay.io/fitbeard/automation-platform/eda-server-operator}"
IMAGE_TAG="${IMAGE_TAG:-$VERSION}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER_NAME="aap-operators-multiarch"

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

echo "==> Applying ${#CHERRY_PICKS[@]} upstream cherry-picks:"
for sha in "${CHERRY_PICKS[@]}"; do
    short="$(git rev-parse --short=8 "$sha")"
    subject="$(git log --format='%s' -n 1 "$sha")"
    echo "    $short  $subject"
    git cherry-pick --allow-empty --keep-redundant-commits --quiet "$sha"
done

cd "$SCRIPT_DIR"

# --- Apply local patches on top of upstream cherry-picks ---------------------
if [[ -x "${SCRIPT_DIR}/patch.sh" ]]; then
    "${SCRIPT_DIR}/patch.sh"
fi

echo "==> src/ ready at $(cd "$SRC_DIR" && git rev-parse --short HEAD)"

# --- Snapshot CRDs to eda-server-operator/crds/ -------------------------------
CRDS_OUT="${SCRIPT_DIR}/crds"
echo "==> Snapshotting CRDs to $(realpath --relative-to="$PWD" "$CRDS_OUT" 2>/dev/null || echo "$CRDS_OUT")/"
rm -rf "$CRDS_OUT"
mkdir -p "$CRDS_OUT"
cp "${SRC_DIR}"/config/crd/bases/eda.ansible.com_*.yaml "$CRDS_OUT"/
echo "==> CRDs ($(ls "$CRDS_OUT" | wc -l | tr -d ' ')): $(ls "$CRDS_OUT" | tr '\n' ' ')"

# --- Build -------------------------------------------------------------------

if [[ $PREP_ONLY -eq 1 ]]; then
    echo "==> --prep-only: skipping docker build"
    exit 0
fi

echo "==> Building ${IMAGE_NAME}:${IMAGE_TAG}"

BUILD_ARGS=(
    --build-arg "OPERATOR_VERSION=${VERSION}"
    --build-arg "DEFAULT_EDA_VERSION=${DEFAULT_EDA_VERSION}"
    --build-arg "DEFAULT_EDA_UI_VERSION=${DEFAULT_EDA_UI_VERSION}"
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
