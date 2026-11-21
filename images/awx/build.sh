#!/usr/bin/env bash
#
#
# Why SRPM and not upstream git clone:
#   automation-controller 4.7.10 ships commit 9594d03dd537 from a PRIVATE
#   stable-2.6 branch — `git fetch origin 9594d03d` against ansible/awx
#   returns "not our ref". The public ansible/awx has no stable-* branches.
#   Delta from public 4.7.8 is 226 modified + 20 new files (dispatcherd
#   rewrite, indirect node counting, ~50 dep bumps) — too large to cherry-
#   pick by hand. SRPM tarball is the only transparent route.
#
#   SRPM is public on the vendor FTP, Apache-2.0, %prep has ZERO %patchN or
#   git apply directives — the tarball IS the complete source.
#
#   UI source (aap-ui) lives in a non-public vendor source tree
#   (aap-ui) — SRPM is mandatory there regardless.
#
# Usage:
#   ./build.sh                                     # Build for local platform
#   ./build.sh --platform linux/arm64              # Build specific arch locally
#   ./build.sh --push                              # Build multiarch (amd64+arm64) and push
#   ./build.sh --no-cache                          # Force full rebuild (no Docker cache)
#   PLATFORMS=linux/amd64 ./build.sh --push        # Push single arch to registry
#   VERSION=26.0.0 ./build.sh                      # Override image tag
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- SRPM sources (public FTP, Apache-2.0) -----------------------------------

AWX_SRPM_URL="https://ftp.redhat.com/redhat/linux/enterprise/9Base/en/AnsibleAutomationPlatform/SRPMS/automation-controller-4.7.20-1.el9ap.src.rpm"
AWX_SRPM_DIR="${SCRIPT_DIR}/awx-srpm"
AWX_TARBALL_GLOB="automation-controller-*.tar.gz"

AAP_UI_SRPM_URL="https://ftp.redhat.com/redhat/linux/enterprise/9Base/en/AnsibleAutomationPlatform/SRPMS/automation-platform-ui-2.6.16-1.el9ap.src.rpm"
AAP_UI_SRPM_DIR="${SCRIPT_DIR}/aap-ui-srpm"
AAP_UI_TARBALL_GLOB="aap-ui-*.tar.gz"

# --- Public git refs we still use --------------------------------------------

AWX_LOGOS_REPO="https://github.com/ansible/awx-logos.git"
AWX_LOGOS_COMMIT="bae4e6cfd16f5e7b814ed873a2fef68b6d90a354"
AWX_LOGOS_DIR="${AWX_LOGOS_DIR:-${SCRIPT_DIR}/awx-logos}"

# DAB commit on public ansible/django-ansible-base — devel commit nearest the
# AAP 2.6.20261116 SRPM cut (controller 4.7.20 was cut 2026-11-09; the gateway/UI
# SRPMs in the same wave are cut 2026-11-16). 4f7889a8 was committed
# 2026-11-12T20:38Z ("[AAP-102150] Update python cryptography") — the closest
# publicly-reachable devel point that spans the whole wave and matches the SRPM's
# cryptography 46.0.7 bump. The 4.7.20 SRPM ships the vendored stable-2.6 DAB
# `91ccee049049` (version 2.6.20261116, NOT on public github); we chase public
# devel-on-the-cut-date instead, kept in parity across AWX/EDA/gateway for
# JWT/resource-server interop. AWX references no new DAB symbols across these
# patch bumps, so the public-only chain resolves.
DAB_COMMIT="4f7889a86d6479217e81d99fc46dadd5ea763432"

# --- Image configuration -----------------------------------------------------

# Clean version scheme for the SRPM-based rebuild, kept inside the AAP 2.6 line:
# 25.0.0 = controller 4.7.11, 26.0.0 = controller 4.7.16, 26.1.0 = controller
# 4.7.20 refresh (minor bump — still AAP 2.6, not a major).
VERSION="${VERSION:-26.1.0}"
IMAGE_NAME="${IMAGE_NAME:-quay.io/fitbeard/automation-platform/awx}"
IMAGE_TAG="${IMAGE_TAG:-$VERSION}"

BUILD_DIR="${BUILD_DIR:-${SCRIPT_DIR}/awx-src}"
AAP_UI_DIR="${AAP_UI_DIR:-${SCRIPT_DIR}/aap-ui}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER_NAME="awx-multiarch"

# DAB setuptools_scm pretend version. DAB commit 4f7889a8 is dated 2026-11-12
# on public devel; we use the commit-date pseudo-version to keep it monotonic
# with the SRPM cut date.
DAB_PRETEND_VERSION="${DAB_PRETEND_VERSION:-2.6.20261112}"

# --- Pre-flight --------------------------------------------------------------

for cmd in git curl docker rpm2cpio cpio tar python3; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' is required but not found in PATH."
        echo "  On macOS: brew install rpm2cpio"
        echo "  On Debian/Ubuntu: apt install rpm2cpio cpio"
        echo "  On RHEL/Fedora: dnf install rpm cpio"
        exit 1
    fi
done

# Cross-platform sed in-place
sedi() { if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi; }

PUSH=false
LOCAL_PLATFORM=""
NO_CACHE=false
while [ $# -gt 0 ]; do
    case "$1" in
        --push) PUSH=true ;;
        --platform) LOCAL_PLATFORM="$2"; shift ;;
        --no-cache) NO_CACHE=true ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
    shift
done

echo "=== AWX Rebuild from AAP SRPM (controller 4.7.20) ==="
echo "  SRPM:      automation-controller-4.7.20-1.el9ap.src.rpm"
echo "  UI SRPM:   automation-platform-ui-2.6.16-1.el9ap.src.rpm"
echo "  Version:   ${VERSION}"
echo "  Image:     ${IMAGE_NAME}:${IMAGE_TAG}"
if [ "${PUSH}" = true ]; then
    echo "  Platforms: ${PLATFORMS}"
elif [ -n "${LOCAL_PLATFORM}" ]; then
    echo "  Platform:  ${LOCAL_PLATFORM}"
else
    echo "  Platform:  (native)"
fi
echo "  Push:      ${PUSH}"
echo "  No cache:  ${NO_CACHE}"
echo ""

# -------------------------------------------------------------------
# Always start fresh: wipe extracted trees so patches apply cleanly.
# The downloaded .src.rpm files are kept to avoid re-downloading 140 MB.
# -------------------------------------------------------------------
echo "=> Wiping extracted trees for a fresh start"
rm -rf "${BUILD_DIR}" "${AAP_UI_DIR}"
echo ""

# -------------------------------------------------------------------
# 1. Download (if missing) + extract AWX SRPM
# -------------------------------------------------------------------
mkdir -p "${AWX_SRPM_DIR}"
AWX_SRPM_FILE="${AWX_SRPM_DIR}/$(basename "${AWX_SRPM_URL}")"
if [ ! -f "${AWX_SRPM_FILE}" ]; then
    echo "=> Downloading AWX SRPM (140 MB)..."
    curl -fSL -o "${AWX_SRPM_FILE}" "${AWX_SRPM_URL}"
fi
echo "=> Extracting AWX SRPM..."
# Clear any old tarballs from prior versions so the glob below matches one file
find "${AWX_SRPM_DIR}" -maxdepth 1 -type f ! -name '*.src.rpm' -delete
(cd "${AWX_SRPM_DIR}" && rpm2cpio "${AWX_SRPM_FILE}" | cpio -idm --quiet 2>/dev/null)
AWX_TARBALL=$(ls ${AWX_SRPM_DIR}/${AWX_TARBALL_GLOB} 2>/dev/null | head -1)
if [ -z "${AWX_TARBALL}" ]; then
    echo "   ERROR: Could not find ${AWX_TARBALL_GLOB} in SRPM contents"
    exit 1
fi
echo "   Found: $(basename "${AWX_TARBALL}")"
mkdir -p "${BUILD_DIR}"
tar xzf "${AWX_TARBALL}" -C "${BUILD_DIR}" --strip-components=1
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 2. Download (if missing) + extract UI SRPM
# -------------------------------------------------------------------
mkdir -p "${AAP_UI_SRPM_DIR}"
UI_SRPM_FILE="${AAP_UI_SRPM_DIR}/$(basename "${AAP_UI_SRPM_URL}")"
if [ ! -f "${UI_SRPM_FILE}" ]; then
    echo "=> Downloading UI SRPM..."
    curl -fSL -o "${UI_SRPM_FILE}" "${AAP_UI_SRPM_URL}"
fi
echo "=> Extracting UI SRPM..."
find "${AAP_UI_SRPM_DIR}" -maxdepth 1 -type f ! -name '*.src.rpm' -delete
(cd "${AAP_UI_SRPM_DIR}" && rpm2cpio "${UI_SRPM_FILE}" | cpio -idm --quiet 2>/dev/null)
UI_TARBALL=$(ls ${AAP_UI_SRPM_DIR}/${AAP_UI_TARBALL_GLOB} 2>/dev/null | head -1)
if [ -z "${UI_TARBALL}" ]; then
    echo "   ERROR: Could not find ${AAP_UI_TARBALL_GLOB} in SRPM contents"
    exit 1
fi
echo "   Found: $(basename "${UI_TARBALL}")"
mkdir -p "${AAP_UI_DIR}"
tar xzf "${UI_TARBALL}" -C "${AAP_UI_DIR}" --strip-components=1
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 3. Fetch official AWX branding assets (public ansible/awx-logos).
#    The SRPM ships `controller-assets-*.tar.gz` with brand-logos;
#    we skip that and use the community awx-logos instead.
# -------------------------------------------------------------------
echo "=> Fetching AWX logos from ${AWX_LOGOS_REPO} @ ${AWX_LOGOS_COMMIT:0:12}..."
if [ ! -d "${AWX_LOGOS_DIR}" ]; then
    git clone --quiet "${AWX_LOGOS_REPO}" "${AWX_LOGOS_DIR}"
fi
(cd "${AWX_LOGOS_DIR}" && git fetch --quiet origin && git checkout --quiet "${AWX_LOGOS_COMMIT}")
echo "   Done."
echo ""

cd "${BUILD_DIR}"

# -------------------------------------------------------------------
# 4. Rewrite requirements_git.txt — replace private SSH/branch refs
#    with public HTTPS commit pins.
#
#    Upstream 4.7.10 ships:
#      certifi @ git+https://github.com/ansible/system-certifi.git@devel
#      django-ansible-base @ git+ssh://git@github.com/ansible-automation-platform/django-ansible-base@stable-2.6
#
#    Replace with public HTTPS + pinned commits (same commits ships
#    as source tarballs in the SRPM).
# -------------------------------------------------------------------
echo "=> Rewriting requirements_git.txt to public HTTPS pins..."
cat > requirements/requirements_git.txt << REQUIREMENTS_GIT
certifi @ git+https://github.com/ansible/system-certifi.git@5aa52ab91f9d579bfe52b5acf30ca799f1a563d9
django-ansible-base[feature-flags,jwt-consumer,rbac,resource-registry,rest-filters] @ git+https://github.com/ansible/django-ansible-base.git@${DAB_COMMIT}
REQUIREMENTS_GIT
# Clear any leaked credentials file
: > requirements/requirements_git.credentials.txt
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 5. CVE bumps on pinned deps.
#
#    RESET 2026-11 (4.7.20 wave): all prior per-dep overrides were removed
#    first, then a clean 4.7.20 image was scanned with `docker scout cves`.
#    The 4.7.20 SRPM already carries every fix we used to force last wave —
#    gitpython 3.2.1 (was sed 3.1.59), django 5.2.17 (was 5.2.13), sqlparse
#    0.6.0, urllib3 2.8.0 (CVE-2026-97689/-97687, per %changelog), cryptography
#    46.0.7, requests 2.32.3, pyjwt 2.15.1, setuptools 80.9.0. Upstream also
#    ships its own pip/distlib patch, applied via `make patch_pip` in the
#    Dockerfile.
#
#    The bumps below are ONLY the residual critical/high findings from that
#    scan that (a) have a stable fix and (b) install as wheels (none are in
#    the Makefile SRC_ONLY_PKGS list cffi,lxml,pycparser,psycopg,twilio,xmlsec,
#    so no source recompile). Each clears its finding without a major-version
#    risk.
# -------------------------------------------------------------------
echo "=> Re-applying residual CVE bumps (post-scan)..."
REQFILE="requirements/requirements.txt"

# HIGH×11: aiohttp 3.14.3 → 3.14.4 (CVE-2026-128124/-128126..128132, -123817,
# -111064/-111066 — resource-consumption/ReDoS cluster). Patch bump; the
# [speedups] extra is preserved. The aio stack is pip-compiled to exact pins, so
# three transitive deps move together: aiohttp 3.14.4 needs yarl>=1.25.1, and
# yarl 1.25.1 in turn needs propcache>=0.2.1. Co-bump yarl 1.17.2->1.25.1 (current
# 1.x) and propcache 0.2.0->0.3.1 to avoid a ResolutionImpossible. (multidict
# 6.0.5, frozenlist 1.8.0, aiosignal 1.4.0, aiohappyeyeballs 2.6.1 already
# satisfy aiohttp 3.14.4's bounds.)
sedi 's/^aiohttp\[speedups\]==3.14.3$/aiohttp[speedups]==3.14.4/' "$REQFILE"
sedi 's/^yarl==1.17.2$/yarl==1.25.1/' "$REQFILE"
sedi 's/^propcache==0.2.0$/propcache==0.3.1/' "$REQFILE"

# HIGH×4: pyasn1 0.6.4 → 0.6.5 (CVE-2026-119194..119197 algorithmic-complexity).
sedi 's/^pyasn1==0.6.4$/pyasn1==0.6.5/' "$REQFILE"

# HIGH×3: msgpack 1.1.1 → 1.2.3 (GHSA-6v7p use-after-free, CVE-2026-57585, and
# CVE-2026-114613 mem-leak fixed in 1.2.3). Still 1.1.1 in the 4.7.20 SRPM.
sedi 's/^msgpack==1.1.1$/msgpack==1.2.3/' "$REQFILE"

# HIGH: azure-core 1.30.0 → 1.38.0 (CVE-2026-21226 untrusted deserialization).
# Still 1.30.0 in the 4.7.20 SRPM.
sedi 's/^azure-core==1.30.0$/azure-core==1.38.0/' "$REQFILE"

# cryptography 46.0.7: NOT bumpable — LEFT at upstream. Its 3 highs (GHSA-537c
# OOB read fix 48.0.1, CVE-2026-69249 DoS fix 49.0.0, CVE-2026-69247 timing fix
# 50.0.0) all need >=48.0.1, but pyopenssl==26.0.0 hard-caps cryptography<47 (and
# msal==1.35.1 caps <49). A bump is ResolutionImpossible without also bumping
# pyopenssl + msal — a cascading crypto/Azure-stack change deferred.

# Deliberately NOT bumped — residual critical/high, each with a reason (post-scan
# 2026-11, docker scout cves --only-severity critical,high):
#   - go stdlib 1.26.7 (2C+9H ×2 binaries, fix 1.26.9): vendor Go binaries
#     (podman-remote, git-lfs) in the Rocky 9 base image; 1.26.9 is not yet in
#     Rocky 9.8. Tracked by the Dockerfile `dnf -y update`. Not built by us.
#   - certifi 2026.1.4 (1C GHSA-6q48 cert-validation): FALSE POSITIVE. This is
#     the ansible/system-certifi shim — certifi.where() resolves to the OS trust
#     store /etc/pki/tls/certs/ca-bundle.crt, NOT a bundled cacert.pem, so the
#     compromised-root advisory does not apply; OS CA trust is kept current by
#     `dnf -y update` (ca-certificates). scout only matches the version string.
#   - djangorestframework 3.15.2 → 3.18.2 (3H data-amplification/DoS): AWX core
#     framework hard-pins 3.15.2; 3.15→3.18 is a breaking jump. Deferred (API
#     regression risk, needs its own validation).
#   - twisted 24.7.0 (5H): every fix is a pre-release (26.4.0rc2 / 26.10.0rc1).
#   - social-auth-core 4.5.4 → 5.0.0 (1H), oauthlib 3.2.2 → 4.0.0 (1H): major
#     auth-stack bumps; DAB pins the social-auth chain. Deferred.
#   - lxml 4.9.4 → 6.x (1H XXE): SRC_ONLY (source-compiled) + major; SAML/XML
#     regression risk. Deferred.
#   - protobuf 4.25.8 → 6.x (1H): major bump; gRPC/operator wire-compat risk.
#   - vim 8.2.2637-43 (1H, fix -44): Rocky 9 base-image rpm; caught by `dnf -y
#     update` once Rocky ships -44.
#   - setuptools 68.2.2 (system RPM) / 70.3.0, wheel 0.45.1, jaraco-context 5.3.0
#     (setuptools/_vendor), urllib3 1.26.20, msgpack 1.1.2: SHADOWS/false
#     positives — the awx venv actually ships setuptools 80.9.0, wheel 0.46.3,
#     jaraco.context 4.3.0, urllib3 2.8.0, msgpack 1.2.3 (the bumped runtime deps
#     above). The flagged older copies are not on the awx import path.

echo "   Patched $(grep -c '==' "$REQFILE") pinned packages"
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 6. Patch AWX metadata to expose content_type choices for role_definitions.
#    The aap-ui fetches OPTIONS /api/v2/role_definitions/ and reads
#    actions.GET.content_type.choices to populate the "Resource type"
#    dropdown.  AWX's Metadata class skips choices for RelatedField
#    subclasses; DAB's RoleDefinitionSerializer uses SlugRelatedField for
#    content_type.  Patch get_field_info() to add choices for
#    SlugRelatedField fields whose queryset is DABContentType.
# -------------------------------------------------------------------
echo "=> Patching metadata.py to expose content_type choices..."
python3 -c "
f = 'awx/api/metadata.py'
content = open(f).read()

import_line = 'from ansible_base.rbac.models import DABContentType'
import_anchor = 'from awx.'
idx = content.index(import_anchor)
content = content[:idx] + import_line + '\n' + content[idx:]

old = '''        if not isinstance(field, (RelatedField, ManyRelatedField)) and hasattr(field, 'choices'):'''
new = '''        # Expose content_type choices for DAB RBAC SlugRelatedField (needed by ui_next)
        if isinstance(field, RelatedField) and hasattr(field, 'get_queryset'):
            qs = field.get_queryset()
            if qs is not None and qs.model is DABContentType:
                field_info['choices'] = [
                    (ct.api_slug, ct.model_class()._meta.verbose_name.title())
                    for ct in qs if ct.model_class() is not None
                ]

        if not isinstance(field, (RelatedField, ManyRelatedField)) and hasattr(field, 'choices'):'''
content = content.replace(old, new, 1)
open(f, 'w').write(content)
"
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 7. Copy official AWX logos into the UI source + static media dirs.
# -------------------------------------------------------------------
echo "=> Copying AWX logos into UI build sources..."
cp "${AWX_LOGOS_DIR}/awx/ui/client/assets/logo-login.svg" "${AAP_UI_DIR}/frontend/assets/awx-logo.svg" 2>/dev/null || true
cp "${AWX_LOGOS_DIR}/awx/ui/client/assets/favicon.ico"    "${AAP_UI_DIR}/frontend/awx/favicon.ico"     2>/dev/null || true
cp "${AWX_LOGOS_DIR}/awx/ui/client/assets/favicon.svg"    "${AAP_UI_DIR}/frontend/assets/awx-icon.svg" 2>/dev/null || true
# Vite copies public/ verbatim into dist/ — replace the angry-potato icon there too
cp "${AWX_LOGOS_DIR}/awx/ui/client/assets/favicon.svg"    "${AAP_UI_DIR}/frontend/awx/public/awx-icon.svg" 2>/dev/null || true
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 8. Make the new UI the default (replace old CRA/webpack UI).
#    - Patch IndexView to serve index_awx.html (Vite build)
#    - Ensure ui_next is in STATICFILES_DIRS so collectstatic picks it up
#    - Remove old ui/build/static entry (the CRA UI is not built)
# -------------------------------------------------------------------
echo "=> Patching AWX to serve new UI as default..."

# 8a. Root IndexView serves Vite-built index_awx.html
sedi "s/template_name = 'index.html'/template_name = 'index_awx.html'/" awx/ui/urls.py

# 8b. STATICFILES_DIRS fixup: add ui_next/build/awx, drop dead ui/build/static
python3 -c "
f = 'awx/settings/defaults.py'
content = open(f).read()
old = 'STATICFILES_DIRS = ['
new = \"\"\"STATICFILES_DIRS = [
    ('awx', os.path.join(BASE_DIR, 'ui_next', 'build', 'awx')),\"\"\"
content = content.replace(old, new, 1)
content = content.replace(\"    os.path.join(BASE_DIR, 'ui', 'build', 'static'),\n\", '')
open(f, 'w').write(content)
"

# 8c. Copy official logos into old UI static/media (fallback paths)
cp "${AWX_LOGOS_DIR}/awx/ui/client/assets/"* awx/ui/public/static/media/
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 8d. Debrand About modal trademark.
#     Source: aap-ui/frontend/common/AboutModal.tsx — shared by AWX/EDA/etc.
#     Year is already dynamic via `new Date().getFullYear()`. The hardcoded
#     "Copyright ..." trademark stays inappropriate for our
#     public AWX rebuild — drop the entire wrapper, keep just `{year}`.
#     Stale translation entries in locales/<lang>/translation.json fall
#     through to the new English source string (i18next default behavior).
# -------------------------------------------------------------------
echo "=> Debranding About modal trademark in aap-ui..."
# Structural match on "Copyright {{fullYear}} <anything>, Inc." — no vendor literal.
sedi -E 's|Copyright \{\{fullYear\}\} .+, Inc\.|{{fullYear}}|g' "${AAP_UI_DIR}/frontend/common/AboutModal.tsx"
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 9. Install rendered configs into _build/
# -------------------------------------------------------------------
echo "=> Installing rendered configs into _build/..."
mkdir -p _build
cp "${SCRIPT_DIR}/supervisor_web.conf"     _build/supervisor_web.conf
cp "${SCRIPT_DIR}/supervisor_task.conf"    _build/supervisor_task.conf
cp "${SCRIPT_DIR}/supervisor_rsyslog.conf" _build/supervisor_rsyslog.conf
cp "${SCRIPT_DIR}/nginx.conf"              _build/nginx.conf
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 10. Ensure aap-ui is inside the Docker build context.
#     AAP_UI_DIR lives outside BUILD_DIR (cached independently) but
#     Docker COPY needs it inside the context.
# -------------------------------------------------------------------
if [ "$(cd "${AAP_UI_DIR}" && pwd)" != "$(cd "${BUILD_DIR}/aap-ui" 2>/dev/null && pwd)" ]; then
    echo "=> Copying aap-ui into Docker build context..."
    rm -rf "${BUILD_DIR}/aap-ui"
    cp -a "${AAP_UI_DIR}" "${BUILD_DIR}/aap-ui"
    echo "   Done."
    echo ""
fi

cd "${SCRIPT_DIR}"

# -------------------------------------------------------------------
# 11. Build the container image.
# -------------------------------------------------------------------
BUILDX_ARGS=(
    -f "${SCRIPT_DIR}/Dockerfile"
    --build-arg "VERSION=${VERSION}"
    --build-arg "SETUPTOOLS_SCM_PRETEND_VERSION=${VERSION}"
    --build-arg "DAB_PRETEND_VERSION=${DAB_PRETEND_VERSION}"
    -t "${IMAGE_NAME}:${IMAGE_TAG}"
)

if [ "${NO_CACHE}" = true ]; then
    BUILDX_ARGS+=(--no-cache)
fi

if [ "${PUSH}" = true ]; then
    echo "=> Ensuring buildx builder '${BUILDER_NAME}' exists..."
    if ! docker buildx inspect "${BUILDER_NAME}" &>/dev/null; then
        docker buildx create --name "${BUILDER_NAME}" --driver docker-container --use
    else
        docker buildx use "${BUILDER_NAME}"
    fi
    echo "=> Building multiarch and pushing to registry..."
    docker buildx build "${BUILDX_ARGS[@]}" \
        --platform "${PLATFORMS}" \
        --push \
        "${BUILD_DIR}"
elif [ -n "${LOCAL_PLATFORM}" ]; then
    echo "=> Building for ${LOCAL_PLATFORM} (local)..."
    DOCKER_BUILDKIT=1 docker buildx build "${BUILDX_ARGS[@]}" \
        --platform "${LOCAL_PLATFORM}" \
        --load \
        "${BUILD_DIR}"
else
    echo "=> Building for local use..."
    DOCKER_BUILDKIT=1 docker build "${BUILDX_ARGS[@]}" "${BUILD_DIR}"
fi

echo ""
echo "=== Build complete ==="
echo "  Image: ${IMAGE_NAME}:${IMAGE_TAG}"
if [ "${PUSH}" = true ]; then
    echo "  Platforms: ${PLATFORMS}"
    echo "  Pushed to registry."
else
    echo ""
    echo "  Quick test:"
    echo "    docker run --rm -e AWX_MODE=defaults -e SKIP_SECRET_KEY_CHECK=yes -e SKIP_PG_VERSION_CHECK=yes ${IMAGE_NAME}:${IMAGE_TAG} awx-manage version"
    echo ""
    echo "  To build multiarch and push:"
    echo "    ./build.sh --push"
fi
