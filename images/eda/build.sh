#!/usr/bin/env bash
#
# Build EDA Server + EDA UI container images from SRPM sources.
#
# Usage:
#   ./build.sh                                     # Build both images for local platform
#   ./build.sh --platform linux/arm64              # Build specific arch locally
#   ./build.sh --push                              # Build multiarch and push
#   ./build.sh --no-cache                          # Force full rebuild
#   PLATFORMS=linux/amd64 ./build.sh --push        # Push single arch
#   VERSION=1.2.8 ./build.sh                       # Custom version
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# SRPM URLs (public FTP, Apache-2.0 licensed)
EDA_SRPM_URL="https://ftp.redhat.com/redhat/linux/enterprise/9Base/en/AnsibleAutomationPlatform/SRPMS/automation-eda-controller-1.2.8-1.el9ap.src.rpm"
AP_UI_SRPM_URL="https://ftp.redhat.com/redhat/linux/enterprise/9Base/en/AnsibleAutomationPlatform/SRPMS/automation-platform-ui-2.6.8-1.el9ap.src.rpm"

# Local cache directories
EDA_SRPM_DIR="${SCRIPT_DIR}/eda-srpm"
AP_UI_SRPM_DIR="${SCRIPT_DIR}/ap-ui-srpm"
EDA_TARBALL_GLOB="automation-eda-controller-*.tar.gz"
AP_UI_TARBALL_GLOB="aap-ui-*.tar.gz"

# Build directories
BUILD_DIR="${BUILD_DIR:-${SCRIPT_DIR}/eda-src}"
AP_UI_DIR="${AP_UI_DIR:-${SCRIPT_DIR}/ap-ui}"

# DAB commit on public ansible/django-ansible-base — devel HEAD on the day
# the AAP 2.6.8 SRPM was cut (2026-04-23).
DAB_COMMIT="5f6343b9b98c5e48e7a4dc087bf931cd2bd5f104"

# Image configuration
VERSION="${VERSION:-1.2.8}"
UI_VERSION="${UI_VERSION:-2.6.8}"
EDA_IMAGE_NAME="${EDA_IMAGE_NAME:-quay.io/fitbeard/automation-platform/eda-server}"
EDA_IMAGE_TAG="${EDA_IMAGE_TAG:-$VERSION}"
UI_IMAGE_NAME="${UI_IMAGE_NAME:-quay.io/fitbeard/automation-platform/eda-ui}"
UI_IMAGE_TAG="${UI_IMAGE_TAG:-$UI_VERSION}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER_NAME="eda-multiarch"

# Pre-flight: check required tools
for cmd in docker tar curl rpm2cpio cpio; do
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

echo "=== EDA Server + UI Rebuild from SRPM sources ==="
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
# 1. Download + extract EDA SRPM
# -------------------------------------------------------------------
if [ -d "${BUILD_DIR}" ]; then
    echo "=> EDA source already exists: ${BUILD_DIR}"
    echo "   Remove it to force a fresh extract."
else
    mkdir -p "${EDA_SRPM_DIR}"
    SRPM_FILE="${EDA_SRPM_DIR}/$(basename "${EDA_SRPM_URL}")"
    if [ ! -f "${SRPM_FILE}" ]; then
        echo "=> Downloading EDA SRPM..."
        curl -fSL -o "${SRPM_FILE}" "${EDA_SRPM_URL}"
    fi
    echo "=> Extracting EDA SRPM..."
    cd "${EDA_SRPM_DIR}" && rpm2cpio "${SRPM_FILE}" | cpio -idm --quiet 2>/dev/null
    EDA_TARBALL=$(ls ${EDA_SRPM_DIR}/${EDA_TARBALL_GLOB} 2>/dev/null | head -1)
    if [ -z "${EDA_TARBALL}" ]; then
        echo "   ERROR: Could not find ${EDA_TARBALL_GLOB} in SRPM contents"
        exit 1
    fi
    echo "   Found: $(basename "${EDA_TARBALL}")"
    mkdir -p "${BUILD_DIR}"
    tar xzf "${EDA_TARBALL}" -C "${BUILD_DIR}" --strip-components=1
    cd "${SCRIPT_DIR}"
    echo "   Done."
fi
echo ""

# -------------------------------------------------------------------
# 2. Download + extract UI SRPM
# -------------------------------------------------------------------
if [ -d "${AP_UI_DIR}" ]; then
    echo "=> UI source already exists: ${AP_UI_DIR}"
    echo "   Remove it to force a fresh extract."
else
    mkdir -p "${AP_UI_SRPM_DIR}"
    UI_SRPM_FILE="${AP_UI_SRPM_DIR}/$(basename "${AP_UI_SRPM_URL}")"
    if [ ! -f "${UI_SRPM_FILE}" ]; then
        echo "=> Downloading UI SRPM..."
        curl -fSL -o "${UI_SRPM_FILE}" "${AP_UI_SRPM_URL}"
    fi
    echo "=> Extracting UI SRPM..."
    cd "${AP_UI_SRPM_DIR}" && rpm2cpio "${UI_SRPM_FILE}" | cpio -idm --quiet 2>/dev/null
    UI_TARBALL=$(ls ${AP_UI_SRPM_DIR}/${AP_UI_TARBALL_GLOB} 2>/dev/null | head -1)
    if [ -z "${UI_TARBALL}" ]; then
        echo "   ERROR: Could not find ${AP_UI_TARBALL_GLOB} in SRPM contents"
        exit 1
    fi
    echo "   Found: $(basename "${UI_TARBALL}")"
    mkdir -p "${AP_UI_DIR}"
    tar xzf "${UI_TARBALL}" -C "${AP_UI_DIR}" --strip-components=1
    cd "${SCRIPT_DIR}"
    echo "   Done."
fi
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
