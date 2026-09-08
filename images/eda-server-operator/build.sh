#!/usr/bin/env bash
#
# Build EDA Server Operator container image from public upstream code.
#
# Reproduces what ships in platform-operator-bundle:2.6-1787258025-source,
# using only transparent, publicly-verifiable
# operations:
#
#   1. git clone https://github.com/ansible/eda-server-operator
#   2. git checkout b72dbf05498050209cf1ba799af3f0bd2d896d61   (baseline)
#   3. git cherry-pick the public upstream SHAs that carried on top
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
#   - Image:   quay.io/fitbeard/automation-platform/eda-server-operator:2.6-1787258025
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
#   IMAGE_TAG=...        # default: 2.6-1787258025
#   BASELINE_COMMIT=...  # default: b72dbf05...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"

# --- Upstream pin ------------------------------------------------------------

UPSTREAM_URL="https://github.com/ansible/eda-server-operator"
BASELINE_COMMIT="${BASELINE_COMMIT:-b72dbf05498050209cf1ba799af3f0bd2d896d61}"

# Upstream SHAs cherry-picked on top of the baseline. Applied in chronological
# order. Picks 1-7 reproduce AAP 2.6-709; picks 8-15 advance to the
# 2.6-1787258025 bundle. Identified by replaying
# baseline + picks and diffing (FQCN + EDA-kind + image-pin normalized) against
# the bundle source.
#
# Skipped (deliberate). Base image stays ansible-operator v1.36.1 (confirmed in
# BOTH bundles) — downstream never took the operator-sdk upgrades, same as us:
#   b7e4168 — Merge operator-sdk-v1.40.0-upgrade (#323)  *** load-bearing skip ***
#   bb19376 — bump operator-sdk to v1.42.2 (#356)         *** load-bearing skip ***
#   80e750a — sync Makefile + operator-sdk v1.42.3 (#358) *** load-bearing skip ***
#   4c9fd0c/f939b71/6d43ede — redis cleanup + reverts (round-trip)
#   6a5cbe0/1812547 — event-streams / event-persistence (not in bundle)
#   597ddad/03051830 — Makefile standardization (dev-only)
#   21c95bc/3cbbf9b/3415718/7bc9494/9a630ef — CI-only
#   f8aab23 — revert proxy molecule test (test-only)
#   746a39d — remove manager_auth_proxy_patch ref — bundle KEEPS it (kube-rbac-proxy present, base v1.36.1)
#   460e160 — affinity parameter (#307) — NOT in bundle
#   91c0a6f — finalizer playbook (#361) — NOT in bundle
#   (all merge commits skipped; underlying non-merge commits picked directly)
CHERRY_PICKS=(
    "4cd8202304a1904010f625892cc8d943e88dee86"  # 2026-02-03 create_backup_pvc option (#316)               [708]
    "6bf7694465ae8ea72fead93219c62387c50115f5"  # 2026-03-04 backup_pvc custom name in templates (#324)     [708]
    "0f094114d8e24eb2f607073aaabc1b5a19d75414"  # 2026-03-23 Fix unquoted timestamps in event templates    [709]
    "a64e5b10e4c043bdbe199ed4a319e1720ca13708"  # 2026-03-24 Add use_db_compression option (#325)          [709]
    "8fd2fa2cfb7185d1dbe2a1a1f22a08f326cca072"  # 2026-04-01 Add --no-imports to django commands           [709]
    "ccccc992f8417eb137784ff87796c42b535b6a75"  # 2026-04-09 Fix dup Jinja2 close tag (activation-worker)  [709]
    "5183504188245f833d817b0eb8140ee1439bdb9c"  # 2026-04-09 Fix dup Jinja2 close tags (other 2 templates) [709]
    "c13fae8d5468632d0e8b6e9e1d68aea6c7c161ad"  # 2026-04-24 feat: proxy env var support for EDA containers (#341)  [1787258025]
    "afef412f876780b4858992ca5be3d541e53a1eb4"  # 2026-04-27 fix(eda-api): mount bundle_cacert in gunicorn container [1787258025]
    "dd35b5c7fd078f4f6933e01e304f67745c541521"  # 2026-05-06 refactor: proxy env vars -> ConfigMap-only, drop CRD fields (#346) [1787258025]
    "cfdc6b251b24e5cedb2e94813e687e7ff907ec9e"  # 2026-06-10 deprecate postgres_keep_pvc_after_upgrade (#352) [1787258025]
    "1dcdb3fbf1efec5a74d08e423fcb9888d5d47f7d"  # 2026-06-10 Set WORKER_KIND to websocket on daphne          [1787258025]
    "5680468d903a0150a1990bdc4cab68358526ec20"  # 2026-06-15 allow skipping PostgreSQL backup/restore        [1787258025]
    "1570553001e21d7e1e3ee3d27d27af171962e53f"  # 2026-07-23 fix: augment NO_PROXY in proxy-env ConfigMap (#359) [1787258025]
    "0416746d1c74010e02b9de4906913ba5b2ca795e"  # 2026-07-24 fix: remove chmod/chown from backup postgres task (#360) [1787258025]
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

VERSION="${VERSION:-2.6-1787258025}"
DEFAULT_EDA_VERSION="${DEFAULT_EDA_VERSION:-1.2.12}"
DEFAULT_EDA_UI_VERSION="${DEFAULT_EDA_UI_VERSION:-2.6.13}"
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
    if ! git cherry-pick --allow-empty --keep-redundant-commits --quiet "$sha"; then
        # Upstream `main` is non-linear (merge commits, a redis remove/re-add
        # round-trip, postgres_keep_pvc deprecation) so replaying a downstream-
        # selected subset by SHA hits a few structural conflicts. Each is
        # resolved to match the extracted bundle source exactly. Anything not
        # handled below aborts loudly (real drift, not silently resolved).
        unmerged="$(git diff --name-only --diff-filter=U)"
        non_docs="$(printf '%s\n' "$unmerged" | grep -v '^docs/' || true)"

        # docs/upgrade/*.md — NOT shipped in the image; take upstream.
        docs_only="$(printf '%s\n' "$unmerged" | grep '^docs/' || true)"
        if [ -n "$docs_only" ]; then
            # shellcheck disable=SC2086
            git checkout --theirs -- $docs_only && git add -- $docs_only
        fi

        case "$short" in
        1dcdb3fb)
            # WORKER_KIND: upstream removed the redis EDA_MQ_* env block; we (and
            # the bundle) KEEP it. 3-way merge conflicts on the insertion point.
            # Union: keep our redis block (--ours) + append EDA_WORKER_KIND after
            # the redis HA-cluster-hosts entry, matching the bundle's ordering.
            f="roles/eda/templates/eda-api.deployment.yaml.j2"
            git checkout --ours -- "$f"
            # The template has two redis EDA_MQ_* blocks (gunicorn + daphne
            # containers); WORKER_KIND=websocket belongs on the daphne one, so
            # insert after the SECOND `cluster_endpoint / optional: true` (matches
            # the bundle's placement before the daphne resources block).
            perl -0pi -e 'my $c=0; s/(              key: cluster_endpoint\n              optional: true\n)/++$c==2 ? $1 . qq(        - name: EDA_WORKER_KIND\n          value: "websocket"\n) : $1/ge' "$f"
            grep -q 'EDA_WORKER_KIND' "$f" || { echo "ERROR: WORKER_KIND anchor not found for $short" >&2; git cherry-pick --abort; exit 1; }
            git add -- "$f"
            ;;
        5680468d)
            # skip-PostgreSQL-backup/restore: only restore/defaults/main.yml
            # conflicts (a YAML end-marker vs added force_drop_db/postgres_skip_data
            # keys). Bundle has the added keys — take upstream for this file.
            f="roles/restore/defaults/main.yml"
            git checkout --theirs -- "$f" && git add -- "$f"
            ;;
        *)
            if [ -n "$non_docs" ]; then
                echo "    ERROR: cherry-pick $short conflicts outside docs/ with no known resolution:" >&2
                printf '      %s\n' $non_docs >&2
                git cherry-pick --abort
                exit 1
            fi
            ;;
        esac
        echo "      (resolved conflict for $short: $(printf '%s' "$unmerged" | tr '\n' ' '))"
        GIT_EDITOR=true git cherry-pick --continue >/dev/null
    fi
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
