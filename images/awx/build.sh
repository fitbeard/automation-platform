#!/usr/bin/env bash
#
#
# Why the vendor "-source" OCI and not upstream git clone:
#   automation-controller 4.8.14 ships commit 463c7e64 from a non-public
#   vendor branch — the materialized awx tree diverges from public ansible/awx
#   devel by ~162 files at the cut date (downstream security guards, cache.py,
#   a metrics-utility migration), so it is NOT a clean public pull.
#
#   No longer publishes SRPMs — the only source channel is the per-
#   component build-source-image (BSI) "-source" OCI. Inside it, the Konflux
#   build-wrapper carries the private submodules MATERIALIZED at sources/tower
#   (the complete awx source, Apache-2.0 — verified byte-identical to the code
#   shipped in the runtime image, minus tests). Extracting that tree is the
#   direct replacement for the old SRPM tarball (see extract-source-oci.sh).
#
#   UI source (aap-ui, the shared @ansible/ui SPA) is bundled as a submodule in
#   the gateway "-source"; the controller "-source" has none (AAP 2.5+ ships a
#   headless controller). We keep a standalone UI, so we pull aap-ui from the
#   gateway "-source" and build+serve it as in the 2.6 image.
#
# Usage:
#   ./build.sh                                     # Build for local platform
#   ./build.sh --platform linux/arm64              # Build specific arch locally
#   ./build.sh --push                              # Build multiarch (amd64+arm64) and push
#   ./build.sh --no-cache                          # Force full rebuild (no Docker cache)
#   PLATFORMS=linux/amd64 ./build.sh --push        # Push single arch to registry
#   VERSION=27.0.0 ./build.sh                      # Override image tag
#
# Prereq: the two "-source" images must be pulled locally first (needs
# registry.redhat.io auth):
#   docker pull registry.redhat.io/ansible-automation-platform-27/controller-rhel9:4.8.14-1794542126-source
#   docker pull registry.redhat.io/ansible-automation-platform-27/gateway-rhel9:2.7.20261116-1794543629-source
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- "-source" OCI sources (BSI, Apache-2.0; replaces SRPM) ---------
# Pull these locally first (see header). Override with env for a newer cut.

# shellcheck source=extract-source-oci.sh
. "${SCRIPT_DIR}/extract-source-oci.sh"

# Controller app source: materialized awx tree lives at <wrapper>/sources/tower
AWX_SOURCE_IMAGE="${AWX_SOURCE_IMAGE:-registry.redhat.io/ansible-automation-platform-27/controller-rhel9:4.8.14-1794542126-source}"
AWX_SOURCE_SUBPATH="sources/tower"

# Shared platform UI (@ansible/ui): bundled only in the gateway "-source", at
# <wrapper>/aap-ui. The controller "-source" ships no UI (headless since 2.5+).
AAP_UI_SOURCE_IMAGE="${AAP_UI_SOURCE_IMAGE:-registry.redhat.io/ansible-automation-platform-27/gateway-rhel9:2.7.20261116-1794543629-source}"
AAP_UI_SOURCE_SUBPATH="aap-ui"

# Scratch dirs for the two extractions (wiped each run).
AWX_EXTRACT_DIR="${SCRIPT_DIR}/.src-controller"
AAP_UI_EXTRACT_DIR="${SCRIPT_DIR}/.src-gateway"

# --- Public git refs we still use --------------------------------------------

AWX_LOGOS_REPO="https://github.com/ansible/awx-logos.git"
AWX_LOGOS_COMMIT="bae4e6cfd16f5e7b814ed873a2fef68b6d90a354"
AWX_LOGOS_DIR="${AWX_LOGOS_DIR:-${SCRIPT_DIR}/awx-logos}"

# DAB commit on public ansible/django-ansible-base — devel commit nearest
# cut. The controller "-source" vendors DAB at branch 2.7.20261116
# (non-public); the nearest public devel commit on/before 2026-11-16 is
# 4f7889a8 ("[AAP-102150] Update python cryptography", 2026-11-12) — no public
# devel commits landed in the 11-12..11-16 window, so this is the exact nearest
# point (and the same pin the 2.6 wave used, keeping JWT/resource-server parity
# across AWX/EDA/gateway). We chase public devel rather than vendoring the exact
# tree to keep the chain public; the -source DAB tree is Apache-2.0 and could be
# vendored instead if an exact pin is ever required.
DAB_COMMIT="4f7889a86d6479217e81d99fc46dadd5ea763432"

# --- Image configuration -----------------------------------------------------

# Version scheme tracks the awx major per AAP line: 25.x = controller
# 4.7.11, 26.x = controller 4.7.16/4.7.20. controller 4.8.14
# → 27.0.0 (new AP minor = new awx major).
VERSION="${VERSION:-27.0.0}"
IMAGE_NAME="${IMAGE_NAME:-quay.io/fitbeard/automation-platform/awx}"
IMAGE_TAG="${IMAGE_TAG:-$VERSION}"

BUILD_DIR="${BUILD_DIR:-${SCRIPT_DIR}/awx-src}"
AAP_UI_DIR="${AAP_UI_DIR:-${SCRIPT_DIR}/aap-ui}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER_NAME="awx-multiarch"

# DAB setuptools_scm pretend version. Matches the vendored DAB branch date for
# cut (2.7.20261116); DAB commit 4f7889a8 is the nearest public devel.
DAB_PRETEND_VERSION="${DAB_PRETEND_VERSION:-2.7.20261116}"

# --- Pre-flight --------------------------------------------------------------

for cmd in git docker tar python3; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' is required but not found in PATH."
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

echo "=== AWX Rebuild from -source OCI (controller 4.8.14) ==="
echo "  Source:    ${AWX_SOURCE_IMAGE##*/}"
echo "  UI source: ${AAP_UI_SOURCE_IMAGE##*/}"
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
# -------------------------------------------------------------------
echo "=> Wiping extracted trees for a fresh start"
rm -rf "${BUILD_DIR}" "${AAP_UI_DIR}"
echo ""

# -------------------------------------------------------------------
# 1. Extract the controller (awx) source from the "-source" OCI.
#    <wrapper>/sources/tower is the complete awx tree (Apache-2.0),
#    the direct replacement for the old SRPM tarball.
# -------------------------------------------------------------------
echo "=> Extracting controller source from ${AWX_SOURCE_IMAGE##*/}..."
AWX_WRAPPER=$(extract_source_oci "${AWX_SOURCE_IMAGE}" "${AWX_EXTRACT_DIR}")
# LICENSE GATE: refuse to build a distributable image unless the materialized
# controller (awx) tree still ships an OSS LICENSE (see extract-source-oci.sh) —
# catches a future -source bump that drops or relicenses it.
assert_submodule_license "${AWX_WRAPPER}" "${AWX_SOURCE_SUBPATH}"
AWX_TOWER="${AWX_WRAPPER}/${AWX_SOURCE_SUBPATH}"
if [ ! -d "${AWX_TOWER}/awx" ]; then
    echo "   ERROR: no awx tree at ${AWX_SOURCE_SUBPATH} in the -source image"
    exit 1
fi
mkdir -p "${BUILD_DIR}"
# Copy the materialized tree into the build dir (it has no .git).
cp -a "${AWX_TOWER}/." "${BUILD_DIR}/"
echo "   awx source: $(find "${BUILD_DIR}/awx" -name '*.py' | wc -l | tr -d ' ') .py files"
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 2. Extract the shared platform UI (aap-ui) from the gateway "-source".
#    The controller "-source" ships no UI (headless since AAP 2.5+); we keep
#    a standalone UI, so aap-ui comes from the gateway wrapper's submodule.
# -------------------------------------------------------------------
echo "=> Extracting aap-ui from ${AAP_UI_SOURCE_IMAGE##*/}..."
AAP_UI_WRAPPER=$(extract_source_oci "${AAP_UI_SOURCE_IMAGE}" "${AAP_UI_EXTRACT_DIR}")
# LICENSE GATE: the standalone UI comes from the gateway -source wrapper; assert
# its OSS LICENSE before bundling it into a distributable image.
assert_submodule_license "${AAP_UI_WRAPPER}" "${AAP_UI_SOURCE_SUBPATH}"
AAP_UI_SRC="${AAP_UI_WRAPPER}/${AAP_UI_SOURCE_SUBPATH}"
if [ ! -d "${AAP_UI_SRC}/frontend" ]; then
    echo "   ERROR: no aap-ui frontend at ${AAP_UI_SOURCE_SUBPATH} in the gateway -source"
    exit 1
fi
mkdir -p "${AAP_UI_DIR}"
cp -a "${AAP_UI_SRC}/." "${AAP_UI_DIR}/"
# The vendor's package-lock.json pins every tarball to the Konflux hermetic
# Cachi2 offline cache (`file:///cachi2/output/deps/npm/...`), which does not
# exist outside their build. Drop the lockfiles so the Docker build resolves
# from the PUBLIC npm registry at the versions package.json specifies. The
# `.npmrc` supply-chain guards (ignore-scripts, min-release-age=7) are kept.
find "${AAP_UI_DIR}" -name 'package-lock.json' -not -path '*/node_modules/*' -delete
echo "   aap-ui: stripped Cachi2 lockfiles (will resolve from public npm)"
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
# 4. Rewrite requirements_git.txt — replace private SSH/branch refs with public
#    HTTPS commit pins.
#
#    The 4.8.14 controller source ships FOUR git deps (2.7 added the awx-plugins
#    split as git refs):
#      certifi             @ git+https://github.com/ansible/system-certifi.git@devel
#      django-ansible-base @ git+ssh://.../ansible-automation-platform/django-ansible-base@stable-2.7   (non-public)
#      awx-plugins-core    @ git+https://github.com/ansible/awx-plugins.git@devel                       (public)
#      awx-plugins-interfaces @ git+https://github.com/ansible/awx_plugins.interfaces.git               (public)
#    Only DAB is non-public (we pin public devel nearest the cut). The other
#    three are already public; we pin them to public commits nearest 2026-11-16
#    for reproducibility (awx-plugins-core/interfaces @ 2026-11-14).
# -------------------------------------------------------------------
echo "=> Rewriting requirements_git.txt to public HTTPS pins..."
cat > requirements/requirements_git.txt << REQUIREMENTS_GIT
certifi @ git+https://github.com/ansible/system-certifi.git@5aa52ab91f9d579bfe52b5acf30ca799f1a563d9
django-ansible-base[feature-flags,jwt-consumer,rbac,resource-registry,rest-filters] @ git+https://github.com/ansible/django-ansible-base.git@${DAB_COMMIT}
awx-plugins-core[credentials-github-app] @ git+https://github.com/ansible/awx-plugins.git@4332fe3012b6317f680cd35e381e646058d7cfc2
awx-plugins-interfaces @ git+https://github.com/ansible/awx_plugins.interfaces.git@a36102ff9a42ac3ebc3fe489cc65c4cc619a46bd
REQUIREMENTS_GIT
# Clear any leaked credentials file
: > requirements/requirements_git.credentials.txt
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 5. CVE bumps on pinned deps.
#
#    RESET for controller 4.8.14: the whole 2.6 override set is cleared
#    (its seds targeted 4.7.20 pins that no longer exist — e.g. yarl==1.17.2 is
#    now 1.22.0, azure-core 1.30.0→1.35.1, cryptography 46.0.7→47.0.0; a stale
#    aiohttp bump without the matching yarl bump caused a ResolutionImpossible).
#    The 4.8.14 requirements already carry most prior fixes. Per our standing
#    method we build a CLEAN 4.8.14 image FIRST, then `docker scout cves
#    --only-severity critical,high`, then re-apply ONLY the residual fixes that
#    (a) have a stable wheel fix and (b) are not SRC_ONLY / major-version risky.
#
#    Re-audited 2026-11 against a clean awx:27.0.0 (`docker scout cves
#    --only-severity critical,high` = 5C/67H). Bumps below are the residual
#    findings with a stable wheel fix and no major-version / resolution-cap risk.
# -------------------------------------------------------------------
echo "=> Re-applying residual CVE bumps (post-scan, 4.8.14)..."
REQFILE="requirements/requirements.txt"

# HIGH×11: aiohttp 3.14.3 -> 3.14.4. aiohttp 3.14.4 needs yarl>=1.25.1, so co-bump
# yarl 1.22.0 -> 1.25.1 (4.8.14 ships 1.22.0; a lone aiohttp bump is a
# ResolutionImpossible). propcache 0.4.1 already satisfies yarl's >=0.2.1.
sedi 's/^aiohttp\[speedups\]==3.14.3$/aiohttp[speedups]==3.14.4/' "$REQFILE"
sedi 's/^yarl==1.22.0$/yarl==1.25.1/' "$REQFILE"

# HIGH×4: pyasn1 0.6.4 -> 0.6.5 (algorithmic-complexity).
sedi 's/^pyasn1==0.6.4$/pyasn1==0.6.5/' "$REQFILE"

# HIGH×3: msgpack 1.1.1 -> 1.2.3 (use-after-free / mem-leak; fix >=1.2.1).
sedi 's/^msgpack==1.1.1$/msgpack==1.2.3/' "$REQFILE"

# HIGH: azure-core 1.35.1 -> 1.38.0 (CVE-2026-21226 untrusted deserialization).
sedi 's/^azure-core==1.35.1$/azure-core==1.38.0/' "$REQFILE"

# HIGH: dynaconf 3.2.12 -> 3.2.13 (patch fix).
sedi 's/^dynaconf==3.2.12$/dynaconf==3.2.13/' "$REQFILE"

# HIGH: protobuf 6.32.1 -> 6.33.5 (patch within 6.x — no gRPC/wire-compat risk).
sedi 's/^protobuf==6.32.1$/protobuf==6.33.5/' "$REQFILE"

# Deliberately NOT bumped — residual critical/high, each with a reason
# (post-scan 2026-11, scout critical,high on awx:27.0.0):
#   - stdlib Go 1.26.7 (2C+9H ×2 binaries, fix 1.26.9): vendor Go binaries
#     (podman-remote, git-lfs) in the Rocky 9 base; 1.26.9 not yet in Rocky 9.8.
#     Tracked by the Dockerfile `dnf -y update`. Not built by us.
#   - certifi 2026.1.4 (1C GHSA-6q48): FALSE POSITIVE — the system-certifi shim;
#     certifi.where() resolves to the OS trust store (/etc/pki ca-bundle), no
#     bundled cacert.pem, so the compromised-root advisory does not apply.
#   - cryptography 47.0.0 -> 49.0.0 (3H): pyopenssl==26.1.0 + msal==1.34.0 cap the
#     crypto line; a jump to 49 is a cascading crypto/Azure-stack change. Deferred
#     (needs its own resolution validation), as in 2.6.
#   - djangorestframework 3.15.2 -> 3.18.2 (3H): AWX core hard-pins 3.15.2;
#     3.15->3.18 is breaking. Deferred.
#   - twisted 25.5.0 (5H): only fix is a pre-release (26.10.0rc1).
#   - oauthlib 3.3.1 -> 4.0.0 (2H): major; DAB pins the social-auth chain.
#   - SHADOWS/false positives (runtime venv ships the fixed copies): urllib3
#     1.26.20 (runtime is 2.8.0), msgpack 1.1.2 (bumped above), setuptools
#     68.2.2/70.3.0 (venv 80.9.0), wheel 0.45.1, jaraco-context 5.3.0/6.0.1 —
#     flagged older copies are not on the awx import path.

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
# 6b. Restore direct Controller access under the gateway (2.6 parity).
#     2.7 added a block in awx/settings/__init__.py that, when
#     RESOURCE_SERVER__URL is set (i.e. deployed under the gateway),
#     REPLACES REST_FRAMEWORK.DEFAULT_AUTHENTICATION_CLASSES with the
#     gateway JWT consumer ONLY — which blocks direct session/basic login
#     at the Controller (e.g. https://awx.<host>/: /api/login/ sets a
#     session but /api/v2/me/ then 401s as AnonymousUser). The shipped
#     defaults already list the gateway JWT consumer ALONGSIDE
#     SessionAuthentication + LoggedBasicAuthentication, so we neutralise
#     the override: gateway JWT keeps working AND direct login is restored
#     (as in 2.6). All loadable settings files run BEFORE this block, so it
#     can only be changed in source. The assert fails the build loudly if
#     the upstream anchor moves.
# -------------------------------------------------------------------
echo "=> Restoring direct Controller access (neutralise gateway JWT-only enforcement)..."
python3 -c "
f = 'awx/settings/__init__.py'
content = open(f).read()
old = \"if DYNACONF.get('RESOURCE_SERVER__URL', None):\"
new = \"if False and DYNACONF.get('RESOURCE_SERVER__URL', None):  # debrand: keep direct access (session+basic) alongside gateway JWT\"
assert old in content, 'JWT-only enforcement anchor not found in awx/settings/__init__.py'
content = content.replace(old, new, 1)
open(f, 'w').write(content)
"
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 6c. Unlimited open licensing (no subscription enforcement).
#     The .tower_version marker (added for the full credential-type set)
#     flips detect_server_product_name() off 'AWX', which ALSO switches
#     get_licenser() from OpenLicense (community: unlimited, license_type
#     'open') to the subscription-based Licenser → license_type UNLICENSED.
#     access.py::check_license() early-returns only for 'open'; otherwise an
#     UNLICENSED validation (no time_remaining) raises
#     PermissionDenied("License is missing.") and blocks host adds / job
#     launches. This is a debranded unlimited rebuild (as 2.6, which used
#     OpenLicense because the product was 'AWX'), so force OpenLicense.
# -------------------------------------------------------------------
echo "=> Forcing unlimited OpenLicense in get_licenser()..."
python3 -c "
f = 'awx/main/utils/licensing.py'
c = open(f).read()
old = \"        if detect_server_product_name() == 'AWX':\"
new = \"        if True:  # debrand: unlimited open rebuild — always OpenLicense (no subscription enforcement)\"
assert old in c, 'get_licenser() product-name gate anchor not found in licensing.py'
open(f, 'w').write(c.replace(old, new, 1))
"
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 6d. Debrand the browsable-API footer (shown on every /api/* page).
#     awx/templates/rest_framework/api.html hardcodes a vendor copyright
#     line with an external trademark hyperlink. Collapse it to the neutral
#     product name (our debrand convention), dropping the mark + link.
# -------------------------------------------------------------------
echo "=> Debranding browsable-API footer (api.html)..."
python3 -c "
import re
f = 'awx/templates/rest_framework/api.html'
c = open(f).read()
# Replace the footer-copyright div's inner content (a vendor copyright line with a
# trademark hyperlink) STRUCTURALLY — anchored on the CSS class, with a wildcard
# body — so the vendor mark/URL is never written into our source.
pat = re.compile(r'(<div class=\"col-sm-6 footer-copyright\">).*?(</div>)', re.S)
c2, n = pat.subn(r'\1\n        Automation Platform\n      \2', c, count=1)
assert n == 1, 'footer-copyright div not found in api.html'
open(f, 'w').write(c2)
"
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 6e. Debrand residual product-name string literals in awx source
#     (non-UI, non-migration). These are the analytics/insights User-Agent
#     (already 'AWX' under OpenLicense) and now-dead Licenser fields; collapse
#     them structurally so the shipped image carries no mark. Migrations are
#     left untouched (historical inventory-source labels tied to DB state).
# -------------------------------------------------------------------
echo "=> Debranding residual product-name literals in awx source..."
for f in awx/main/utils/common.py awx/main/utils/licensing.py awx/playbooks/action_plugins/insights.py; do
    [ -f "$f" ] && sedi -E 's|([A-Z][a-z]+ )+Automation Platform|Automation Platform|g' "$f"
done
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
# 8. UI serving. Headless and already configures the UI at
#    awx/ui/build/awx: 4.8.14's settings put ui/build/awx in TEMPLATES.DIRS
#    (IndexView resolves index_awx.html there) and ui/build in STATICFILES_DIRS,
#    and awx/ui/urls.py already serves index_awx.html. The Dockerfile builds our
#    Vite UI into awx/ui/build/awx, so NO settings patch is needed (the 2.6 build
#    had to add ui_next/build/awx to STATICFILES_DIRS — obsolete in 2.7).
# -------------------------------------------------------------------
echo "=> Patching AWX UI serving (logos; template/static paths are native in 2.7)..."

# 8a. IndexView already serves index_awx.html on 4.8.14 (sed is a safe no-op if so).
sedi "s/template_name = 'index.html'/template_name = 'index_awx.html'/" awx/ui/urls.py

# 8b. Copy official logos into the UI static/media fallback paths (DRF/api pages
#     reference /static/media/*.svg).
cp "${AWX_LOGOS_DIR}/awx/ui/client/assets/"* awx/ui/public/static/media/ 2>/dev/null || true
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
