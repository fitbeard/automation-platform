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
# Baseline jumps from the 2.6 pin b72dbf05 (operator-sdk v1.36.1) to the
# current devel HEAD, which already contains the v1.40→v1.42.x upgrades (#323/
# #356/#358) + ALL 20 commits the 2.6 build cherry-picked (HEAD 9120da27 was the
# last pick) + the NetworkPolicy/affinity/event-stream work 2.6 skipped — all part
# of the 2.7 era. So the baseline subsumes the whole pick list (cherry-picks empty)
# AND upstream now ships pod affinity natively (roles/eda/defaults affinity:{} +
# deployment templates), so our wave-2 patch 0004 (own affinity impl) is DROPPED.
# Bump this pin as upstream advances.
BASELINE_COMMIT="${BASELINE_COMMIT:-9120da27dbd1}"

# ansible-operator base image (devel HEAD Dockerfile = v1.42.3, the native base).
BASE_IMAGE_TAG="${BASE_IMAGE_TAG:-v1.42.3}"

# No cherry-picks for 2.7 — the baseline above contains them all.
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
DEFAULT_EDA_VERSION="${DEFAULT_EDA_VERSION:-1.3.15}"
DEFAULT_EDA_UI_VERSION="${DEFAULT_EDA_UI_VERSION:-2.7.14}"
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

# Pin the ansible-operator base image in the upstream Dockerfile (HEAD = v1.42.3,
# its native base — ubi-minimal + microdnf; no adaptation needed).
echo "==> Pinning base image: ansible-operator:${BASE_IMAGE_TAG}"
_sedi() { if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi; }
_sedi -E "s|(operator-framework/ansible-operator):v[0-9]+\.[0-9]+\.[0-9]+|\1:${BASE_IMAGE_TAG}|" "${SRC_DIR}/Dockerfile"
grep -m1 '^FROM' "${SRC_DIR}/Dockerfile" | sed 's/^/    /'

echo "==> Applying ${#CHERRY_PICKS[@]} upstream cherry-picks:"
for sha in ${CHERRY_PICKS[@]+"${CHERRY_PICKS[@]}"}; do
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
        non_docs="$(printf '%s\n' "$unmerged" | grep -vE '^(docs/|molecule/)' || true)"

        # docs/ and molecule/ — NOT shipped in the image (docs, test harness);
        # take upstream on any conflict there.
        not_shipped="$(printf '%s\n' "$unmerged" | grep -E '^(docs/|molecule/)' || true)"
        if [ -n "$not_shipped" ]; then
            # shellcheck disable=SC2086
            git checkout --theirs -- $not_shipped && git add -- $not_shipped
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
        9120da27)
            # #376 qualifies BOTH the activation DB host AND the event-persistence
            # DB host for separate namespaces. Neither the bundle nor our tree ships
            # event-streams/event-persistence (6a5cbe0/1812547 skipped), so the
            # activation-db-host hunks apply cleanly while the event-persistence
            # hunks conflict against our retained redis EDA_MQ_* block. Resolve
            # every conflict to --ours (keep redis, drop the event-persistence
            # additions); the cleanly-merged EDA_ACTIVATION_DB_* qualification is
            # preserved. Result matches the bundle (redis kept, no event-persistence,
            # activation host namespace-qualified).
            for f in roles/eda/templates/eda-activation-worker.deployment.yaml.j2 \
                     roles/eda/templates/eda-api.deployment.yaml.j2 \
                     roles/postgres/tasks/set_event_persistence_secret.yml; do
                perl -0pi -e 's/^<<<<<<< [^\n]*\n(.*?)^=======\n.*?^>>>>>>> [^\n]*\n/$1/gms' "$f"
                grep -q '<<<<<<<\|>>>>>>>' "$f" && { echo "ERROR: unresolved markers remain in $f" >&2; git cherry-pick --abort; exit 1; }
                git add -- "$f"
            done
            # take-ours above also dropped the {% endif %} that 9120da27 placed on
            # its (event-persistence) side to close the activation-db-host {% if %}
            # block right before the redis EDA_MQ_HOST env in eda-api. Exactly one
            # such block loses its endif (verified: 1 occurrence). Re-insert it so
            # the Jinja template stays balanced (else the eda-api deployment render
            # fails at deploy_eda.yml "Apply Backend deployment resources").
            api="roles/eda/templates/eda-api.deployment.yaml.j2"
            perl -0pi -e 's/(\n              key: host\n)(        - name: EDA_MQ_HOST\n)/${1}{% endif %}\n${2}/' "$api"
            ifc=$(grep -cE '\{%-? *if ' "$api"); endifc=$(grep -cE '\{%-? *endif' "$api")
            [ "$ifc" = "$endifc" ] || { echo "ERROR: eda-api.deployment Jinja if/endif still unbalanced ($ifc/$endifc)" >&2; git cherry-pick --abort; exit 1; }
            git add -- "$api"
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
