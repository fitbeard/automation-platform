#!/usr/bin/env bash
#
# Build EDA Server + EDA UI container images from the "-source" OCIs
# (SRPM-less). aap-eda from eda-controller-rhel9:-source; the shared aap-ui SPA
# from gateway-rhel9:-source. See extract-source-oci.sh.
#
# Usage:
#   ./build.sh                                     # Build both images for local platform
#   ./build.sh --platform linux/arm64              # Build specific arch locally
#   ./build.sh --push                              # Build multiarch and push
#   ./build.sh --no-cache                          # Force full rebuild
#   PLATFORMS=linux/amd64 ./build.sh --push        # Push single arch
#   VERSION=1.2.12 ./build.sh                      # Custom version
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- "-source" OCI sources (BSI, Apache-2.0; replaces SRPM) ---------
# Pull these locally first (registry.redhat.io auth). Override via env for a
# newer cut. The EDA app source (aap-eda) is materialized at the wrapper root as
# `aap-eda-controller`; the shared platform UI (aap-ui) is bundled only in the
# gateway "-source" at `aap-ui` (the EDA "-source" ships no UI — eda-ui is an
# nginx repackage of static the app build produces).
# shellcheck source=extract-source-oci.sh
. "${SCRIPT_DIR}/extract-source-oci.sh"

EDA_SOURCE_IMAGE="${EDA_SOURCE_IMAGE:-registry.redhat.io/ansible-automation-platform-27/eda-controller-rhel9:1794560971-source}"
EDA_SOURCE_SUBPATH="aap-eda-controller"
AP_UI_SOURCE_IMAGE="${AP_UI_SOURCE_IMAGE:-registry.redhat.io/ansible-automation-platform-27/gateway-rhel9:2.7.20261116-1794543629-source}"
AP_UI_SOURCE_SUBPATH="aap-ui"

# Scratch extraction dirs (wiped each run)
EDA_EXTRACT_DIR="${SCRIPT_DIR}/.src-eda"
AP_UI_EXTRACT_DIR="${SCRIPT_DIR}/.src-gateway"

# Build directories
BUILD_DIR="${BUILD_DIR:-${SCRIPT_DIR}/eda-src}"
AP_UI_DIR="${AP_UI_DIR:-${SCRIPT_DIR}/ap-ui}"

# DAB commit on public ansible/django-ansible-base. Vendors DAB at branch
# 2.7.20261116 (non-public); the nearest public devel commit on/before 2026-11-16
# is 4f7889a8 (2026-11-12) — the SAME pin as the 2.7 controller, for cross-
# component DAB parity (resource-server/JWT interop when controller + EDA share a
# cluster). EDA installs DAB via pip from this SHA (Dockerfile); the app source
# does not bundle DAB.
DAB_COMMIT="4f7889a86d6479217e81d99fc46dadd5ea763432"

# Image configuration (eda 1.3.15, ui branch 2.7.14)
VERSION="${VERSION:-1.3.15}"
UI_VERSION="${UI_VERSION:-2.7.14}"
EDA_IMAGE_NAME="${EDA_IMAGE_NAME:-quay.io/fitbeard/automation-platform/eda-server}"
EDA_IMAGE_TAG="${EDA_IMAGE_TAG:-$VERSION}"
UI_IMAGE_NAME="${UI_IMAGE_NAME:-quay.io/fitbeard/automation-platform/eda-ui}"
UI_IMAGE_TAG="${UI_IMAGE_TAG:-$UI_VERSION}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER_NAME="eda-multiarch"

# Pre-flight: check required tools
for cmd in docker tar; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' is required but not found in PATH."
        exit 1
    fi
done

# Cross-platform sed -i
sedi() {
    if sed --version >/dev/null 2>&1; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

PUSH=false
LOCAL_PLATFORM=""
NO_CACHE=false
while [ $# -gt 0 ]; do
    case "$1" in
        --push) PUSH=true ;;
        --platform) LOCAL_PLATFORM="$2"; shift ;;
        --no-cache) NO_CACHE=true ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
    shift
done

echo "=== EDA Server + UI Rebuild from -source OCIs ==="
echo "  EDA version: ${VERSION}"
echo "  UI version:  ${UI_VERSION}"
echo "  Server:      ${EDA_IMAGE_NAME}:${EDA_IMAGE_TAG}"
echo "  UI:          ${UI_IMAGE_NAME}:${UI_IMAGE_TAG}"
if [ "${PUSH}" = true ]; then
    echo "  Platforms:   ${PLATFORMS}"
elif [ -n "${LOCAL_PLATFORM}" ]; then
    echo "  Platform:    ${LOCAL_PLATFORM}"
else
    echo "  Platform:    (native)"
fi
echo "  Push:        ${PUSH}"
echo "  No cache:    ${NO_CACHE}"
echo ""

# -------------------------------------------------------------------
# Always start fresh: wipe extracted trees so a version bump re-extracts
# (the cached .src.rpm files are kept to avoid re-downloading).
# -------------------------------------------------------------------
echo "=> Wiping extracted trees (${BUILD_DIR}, ${AP_UI_DIR})"
rm -rf "${BUILD_DIR}" "${AP_UI_DIR}"
echo ""

# -------------------------------------------------------------------
# 1. Extract the EDA app source (aap-eda) from the "-source" OCI.
# -------------------------------------------------------------------
echo "=> Extracting EDA source from ${EDA_SOURCE_IMAGE##*/}..."
EDA_WRAPPER=$(extract_source_oci "${EDA_SOURCE_IMAGE}" "${EDA_EXTRACT_DIR}")
# LICENSE GATE: refuse to build a distributable image unless the materialized
# EDA (aap-eda) tree still ships an OSS LICENSE (see extract-source-oci.sh) —
# catches a future -source bump that drops or relicenses it.
assert_submodule_license "${EDA_WRAPPER}" "${EDA_SOURCE_SUBPATH}"
EDA_SRC="${EDA_WRAPPER}/${EDA_SOURCE_SUBPATH}"
if [ ! -d "${EDA_SRC}/src/aap_eda" ]; then
    echo "   ERROR: no aap_eda tree at ${EDA_SOURCE_SUBPATH} in the -source image"
    exit 1
fi
mkdir -p "${BUILD_DIR}"
cp -a "${EDA_SRC}/." "${BUILD_DIR}/"
echo "   aap-eda: $(find "${BUILD_DIR}/src/aap_eda" -name '*.py' | wc -l | tr -d ' ') .py files"
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 2. Extract the shared platform UI (aap-ui) from the gateway "-source".
#    Strip the Cachi2-wired lockfiles so npm resolves from the public registry.
# -------------------------------------------------------------------
echo "=> Extracting aap-ui from ${AP_UI_SOURCE_IMAGE##*/}..."
AP_UI_WRAPPER=$(extract_source_oci "${AP_UI_SOURCE_IMAGE}" "${AP_UI_EXTRACT_DIR}")
# LICENSE GATE: the EDA UI comes from the gateway -source wrapper; assert its OSS
# LICENSE before bundling it into a distributable image.
assert_submodule_license "${AP_UI_WRAPPER}" "${AP_UI_SOURCE_SUBPATH}"
AP_UI_SRC="${AP_UI_WRAPPER}/${AP_UI_SOURCE_SUBPATH}"
if [ ! -d "${AP_UI_SRC}/frontend/eda" ]; then
    echo "   ERROR: no aap-ui frontend/eda at ${AP_UI_SOURCE_SUBPATH} in the gateway -source"
    exit 1
fi
mkdir -p "${AP_UI_DIR}"
cp -a "${AP_UI_SRC}/." "${AP_UI_DIR}/"
# The vendor package-lock.json pins every tarball to the Konflux hermetic Cachi2
# cache (file:///cachi2/...), absent outside their build — drop the lockfiles so
# the UI build resolves from the public npm registry (.npmrc guards kept).
find "${AP_UI_DIR}" -name 'package-lock.json' -not -path '*/node_modules/*' -delete
echo "   aap-ui: stripped Cachi2 lockfiles (will resolve from public npm)"
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 3. DAB handling note
# -------------------------------------------------------------------
echo "=> DAB will be installed in Dockerfile via pip (commit ${DAB_COMMIT:0:12})"
echo "   Poetry can't fetch arbitrary git commits by SHA (GitHub limitation)."
echo "   Dockerfile removes DAB from pyproject.toml, exports other deps, installs DAB via pip."
echo ""

# -------------------------------------------------------------------
# 4. Patch metadata.py — expose content_type choices for role_definitions
#    The UI fetches OPTIONS /api/eda/v1/role_definitions/ and reads
#    actions.GET.content_type.choices to populate the "Resource type" dropdown.
#    EDAMetadata skips choices for RelatedField subclasses, but DAB's
#    RoleDefinitionSerializer uses SlugRelatedField for content_type.
# -------------------------------------------------------------------
echo "=> Patching metadata.py to expose content_type choices..."
python3 -c "
f = '${BUILD_DIR}/src/aap_eda/api/metadata.py'
content = open(f).read()

import_line = 'from rest_framework.relations import RelatedField'
if import_line not in content:
    content = import_line + '\n' + content

if 'DABContentType' not in content:
    old = '        field_info = super().get_field_info(field)'
    new = '''        field_info = super().get_field_info(field)

        # Expose content_type choices for DAB RBAC SlugRelatedField (needed by UI)
        if isinstance(field, RelatedField) and hasattr(field, 'get_queryset'):
            from ansible_base.rbac.models import DABContentType
            qs = field.get_queryset()
            if qs is not None and qs.model is DABContentType:
                field_info['choices'] = [
                    {'value': ct.api_slug, 'display_name': force_str(ct.model_class()._meta.verbose_name.title(), strings_only=True)}
                    for ct in qs if ct.model_class() is not None
                ]'''
    content = content.replace(old, new, 1)
open(f, 'w').write(content)
"
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 5. Copy UI source into Docker build context (for Dockerfile.ui)
# -------------------------------------------------------------------
if [ "$(cd "${AP_UI_DIR}" && pwd)" != "$(cd "${BUILD_DIR}/ap-ui" 2>/dev/null && pwd)" ]; then
    echo "=> Copying UI source into Docker build context..."
    rm -rf "${BUILD_DIR}/ap-ui"
    cp -a "${AP_UI_DIR}" "${BUILD_DIR}/ap-ui"
    echo "   Done."
    echo ""
fi

# -------------------------------------------------------------------
# 6. Patch EDA UI — product name, version, copyright
# -------------------------------------------------------------------
echo "=> Patching EDA UI (About modal + vite config)..."
UI_BUILD_DIR="${BUILD_DIR}/ap-ui"

# 6a. vite.config.ts: inject PRODUCT and VERSION into process.env define
sedi "s|EDA_API_PREFIX: '/api/eda/v1',|EDA_API_PREFIX: '/api/eda/v1',\n  PRODUCT: 'EDA',\n  VERSION: '${VERSION}',|" \
    "${UI_BUILD_DIR}/frontend/eda/vite.config.ts"

# 6b. AboutModal.tsx: strip vendor copyright, neutral year-only.
#     Structural match on "Copyright {{fullYear}} <anything>, Inc." — no literal.
sedi -E 's|Copyright \{\{fullYear\}\} .+, Inc\.|{{fullYear}}|' \
    "${UI_BUILD_DIR}/frontend/common/AboutModal.tsx"

# 6c. Replace documentation links with upstream EDA docs.
#     Structural match on any access.<host>.com/documentation URL (any version/path).
sedi -E 's|https://access\.[a-z]+\.com/documentation[^">]*|https://ansible.readthedocs.io/projects/rulebook/en/latest/|g' \
    "${UI_BUILD_DIR}/frontend/eda/main/EdaMasthead.tsx" \
    "${UI_BUILD_DIR}/frontend/eda/overview/EdaOverview.tsx"

# 6d. Fix Documentation link in masthead — PF v6 DropdownItem needs "to" prop, not "href".
#     The upstream source uses PF v4/v5 pattern (component="a" href=...) which renders
#     a non-navigating button in PF v6. Remove component="a" and replace href with "to"
#     within the documentation DropdownItem block only.
python3 -c "
import re
f = '${UI_BUILD_DIR}/frontend/eda/main/EdaMasthead.tsx'
content = open(f).read()
# Match the documentation DropdownItem block (from id=\"documentation\" to closing >)
content = re.sub(
    r'(<DropdownItem\s[^>]*id=\"documentation\"[^>]*)component=\"a\"',
    r'\1',
    content,
    flags=re.DOTALL
)
content = re.sub(
    r'(<DropdownItem\s[^>]*id=\"documentation\"[^>]*)href=',
    r'\1to=',
    content,
    flags=re.DOTALL
)
open(f, 'w').write(content)
"

# 6e. EdaOverview.tsx welcome card: simplify the "To learn how to get started"
#     sentence — drop the promo "instruct guides" ExternalLink, keep one
#     documentation link (URL already swapped in 6c above). All matches are
#     structural / keyed on non-brand inner text — no vendor URL literal here.
python3 -c "
import re
f = '${UI_BUILD_DIR}/frontend/eda/overview/EdaOverview.tsx'
content = open(f).read()
# (1) intro wording
content = content.replace('To learn how to get started, ', 'To learn how to get started read ')
# (2) first doc link label
content = content.replace('{t\`Documentation.\`}', '{t\`documentation\`}')
# (3) remove the promo ExternalLink, keyed on its non-brand inner text +
#     any https URL (structural — no vendor URL literal appears here)
promo = re.compile(r'\s*<ExternalLink href=\"https://[^\"]*\">\s*\{t\([^)]*check out our instruct guides[^)]*\)\}\s*</ExternalLink>', re.DOTALL)
if not promo.search(content):
    raise SystemExit('EdaOverview.tsx instruct-guides promo link not found — upstream may have refactored')
content = promo.sub('', content)
open(f, 'w').write(content)
"

echo "   Done."
echo ""

# -------------------------------------------------------------------
# 7. Build eda-server image
# -------------------------------------------------------------------
EDA_BUILDX_ARGS=(
    -f "${SCRIPT_DIR}/Dockerfile"
    --build-arg VERSION="${VERSION}"
    --build-arg DAB_COMMIT="${DAB_COMMIT}"
    -t "${EDA_IMAGE_NAME}:${EDA_IMAGE_TAG}"
)

if [ "${NO_CACHE}" = true ]; then
    EDA_BUILDX_ARGS+=(--no-cache)
fi

if [ "${PUSH}" = true ]; then
    echo "=> Ensuring buildx builder '${BUILDER_NAME}' exists..."
    if ! docker buildx inspect "${BUILDER_NAME}" &>/dev/null; then
        docker buildx create --name "${BUILDER_NAME}" --driver docker-container --use
    else
        docker buildx use "${BUILDER_NAME}"
    fi

    echo "=> Building eda-server multiarch and pushing..."
    docker buildx build "${EDA_BUILDX_ARGS[@]}" \
        --platform "${PLATFORMS}" \
        --push \
        "${BUILD_DIR}"
elif [ -n "${LOCAL_PLATFORM}" ]; then
    echo "=> Building eda-server for ${LOCAL_PLATFORM} (local)..."
    DOCKER_BUILDKIT=1 docker buildx build "${EDA_BUILDX_ARGS[@]}" \
        --platform "${LOCAL_PLATFORM}" \
        --load \
        "${BUILD_DIR}"
else
    echo "=> Building eda-server for local use..."
    DOCKER_BUILDKIT=1 docker build "${EDA_BUILDX_ARGS[@]}" "${BUILD_DIR}"
fi

echo ""
echo "  eda-server: ${EDA_IMAGE_NAME}:${EDA_IMAGE_TAG}"
echo ""

# -------------------------------------------------------------------
# 8. Build eda-ui image
# -------------------------------------------------------------------
UI_BUILDX_ARGS=(
    -f "${SCRIPT_DIR}/Dockerfile.ui"
    -t "${UI_IMAGE_NAME}:${UI_IMAGE_TAG}"
)

if [ "${NO_CACHE}" = true ]; then
    UI_BUILDX_ARGS+=(--no-cache)
fi

if [ "${PUSH}" = true ]; then
    echo "=> Building eda-ui multiarch and pushing..."
    docker buildx build "${UI_BUILDX_ARGS[@]}" \
        --platform "${PLATFORMS}" \
        --push \
        "${BUILD_DIR}"
elif [ -n "${LOCAL_PLATFORM}" ]; then
    echo "=> Building eda-ui for ${LOCAL_PLATFORM} (local)..."
    DOCKER_BUILDKIT=1 docker buildx build "${UI_BUILDX_ARGS[@]}" \
        --platform "${LOCAL_PLATFORM}" \
        --load \
        "${BUILD_DIR}"
else
    echo "=> Building eda-ui for local use..."
    DOCKER_BUILDKIT=1 docker build "${UI_BUILDX_ARGS[@]}" "${BUILD_DIR}"
fi

echo ""
echo "=== Build complete ==="
echo "  eda-server: ${EDA_IMAGE_NAME}:${EDA_IMAGE_TAG}"
echo "  eda-ui:     ${UI_IMAGE_NAME}:${UI_IMAGE_TAG}"
if [ "${PUSH}" = true ]; then
    echo "  Platforms:   ${PLATFORMS}"
    echo "  Pushed to registry."
else
    echo ""
    echo "  Quick test:"
    echo "    docker run --rm ${EDA_IMAGE_NAME}:${EDA_IMAGE_TAG} aap-eda-manage --version"
    echo ""
    echo "  To build multiarch and push:"
    echo "    ./build.sh --push"
fi
