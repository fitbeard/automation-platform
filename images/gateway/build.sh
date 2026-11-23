#!/usr/bin/env bash
#
# Build AAP Gateway container image from SRPM source.
#
# Sources are downloaded from public FTP and extracted
# fresh each run — no cached `gateway-src/` reuse.
# Only debrand/ stays as a permanent
# directory because we ship custom assets from there.
#
# Pinned versions (SRPM build dates in comments):
#   - automation-gateway:     2.6.20260824-1 (SRPM cut 2026-08-14)
#   - automation-platform-ui: 2.6.13-1      (same SRPM AWX/EDA use)
#   - django-ansible-base:    4f7889a86d64  (public devel nearest the 2026-11-09 cut; parity w/ AWX 4.7.20 + EDA 1.2.15; override via DAB_COMMIT=...)
#   - python:                 3.12          (matches new gateway SRPM spec)
#
# Usage:
#   ./build.sh                                     # Build for local platform
#   ./build.sh --platform linux/arm64              # Build specific arch locally
#   ./build.sh --push                              # Build multiarch (amd64+arm64) and push
#   ./build.sh --no-cache                          # Force full rebuild (no Docker cache)
#   PLATFORMS=linux/amd64 ./build.sh --push        # Push single arch to registry
#   VERSION=2.6.20260422 ./build.sh                # Custom version tag
#   IMAGE_NAME=my-registry/gateway ./build.sh
#   DAB_COMMIT=<sha> ./build.sh                    # Pin different DAB commit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Pinned versions ---------------------------------------------------------

# --- "-source" OCI source (BSI, Apache-2.0; replaces SRPM) ----------
# The gateway "-source" wrapper bundles BOTH the gateway app (aap-gateway) AND
# the shared platform UI (aap-ui, branch 2.7.14) as submodules at its root — one
# extraction serves both. Pull it locally first (registry.redhat.io auth).
# shellcheck source=extract-source-oci.sh
. "${SCRIPT_DIR}/extract-source-oci.sh"

GATEWAY_SOURCE_IMAGE="${GATEWAY_SOURCE_IMAGE:-registry.redhat.io/ansible-automation-platform-27/gateway-rhel9:2.7.20261116-1794543629-source}"
GATEWAY_SOURCE_SUBPATH="aap-gateway"
AAP_UI_SOURCE_SUBPATH="aap-ui"
GATEWAY_EXTRACT_DIR="${SCRIPT_DIR}/.src-gateway"
AAP_UI_DIR="${AAP_UI_DIR:-${SCRIPT_DIR}/aap-ui}"

VERSION="${VERSION:-2.7.20261116}"
IMAGE_NAME="${IMAGE_NAME:-quay.io/fitbeard/automation-platform/gateway}"
IMAGE_TAG="${IMAGE_TAG:-$VERSION}"
BUILD_DIR="${BUILD_DIR:-${SCRIPT_DIR}/gateway-src}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER_NAME="gateway-multiarch"

# Gateway sets EMAIL_ENFORCEMENT_VIA_SERIALIZER = True on its User model.
# DAB's email-enforcement signals landed on devel 2026-05-06 (d5100f6), so at
# our 4f7889a8 pin (2026-11-12) DAB reads this flag — consistent with gateway's
# own _validate_email_change serializer + reverse-sync GetOrCreateProcessor
# (both enforce the same policy). No behavior conflict. 4f7889a8 is the public
# devel commit nearest the 2.6.20261116 SRPM cut (2026-11-09), kept in parity
# with the AWX 4.7.20 + EDA 1.2.15 refresh.
DAB_COMMIT="${DAB_COMMIT:-4f7889a86d6479217e81d99fc46dadd5ea763432}"

# --- Pre-flight --------------------------------------------------------------

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

# --- CLI flags ---------------------------------------------------------------

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

echo "=== AAP Gateway rebuild from -source OCI (automation-gateway ${VERSION}) ==="
echo "  Version:     ${VERSION}"
echo "  Image:       ${IMAGE_NAME}:${IMAGE_TAG}"
echo "  DAB commit:  ${DAB_COMMIT}"
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
# 1. Always start fresh: wipe extracted trees so debrand applies cleanly
# -------------------------------------------------------------------
echo "=> Wiping extracted trees (${BUILD_DIR}, ${AAP_UI_DIR})"
rm -rf "${BUILD_DIR}" "${AAP_UI_DIR}"
echo ""

# -------------------------------------------------------------------
# 2. Extract the gateway app (aap-gateway) from the "-source" OCI.
#    The same wrapper also carries aap-ui (used in step 6).
# -------------------------------------------------------------------
echo "=> Extracting gateway source from ${GATEWAY_SOURCE_IMAGE##*/}..."
GATEWAY_WRAPPER=$(extract_source_oci "${GATEWAY_SOURCE_IMAGE}" "${GATEWAY_EXTRACT_DIR}")
# LICENSE GATE: the gateway app, platform UI, and bundled DAB all come from this
# -source wrapper (no public gateway-app repo exists). Refuse to build a
# distributable image unless each still ships an OSS LICENSE — catches a future
# -source bump that drops or relicenses a tree. (Verified Apache-2.0 / MPL 2026-11-23.)
assert_submodule_license "${GATEWAY_WRAPPER}" "${GATEWAY_SOURCE_SUBPATH}" "${AAP_UI_SOURCE_SUBPATH}" django-ansible-base
GATEWAY_SRC="${GATEWAY_WRAPPER}/${GATEWAY_SOURCE_SUBPATH}"
if [ ! -d "${GATEWAY_SRC}/aap_gateway_api" ]; then
    echo "   ERROR: no aap_gateway_api tree at ${GATEWAY_SOURCE_SUBPATH} in the -source image"
    exit 1
fi
mkdir -p "${BUILD_DIR}"
cp -a "${GATEWAY_SRC}/." "${BUILD_DIR}/"
echo "   aap-gateway: $(find "${BUILD_DIR}/aap_gateway_api" -name '*.py' | wc -l | tr -d ' ') .py files"
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 3. Pin DAB commit (replace floating @devel with specific commit)
# -------------------------------------------------------------------
echo "=> Pinning django-ansible-base to commit ${DAB_COMMIT}..."
cat > "${BUILD_DIR}/requirements/requirements_git.txt" << GITREQ
django-ansible-base[activitystream,api-documentation,authentication,redis-client,rest-filters,rbac,oauth2-provider,feature-flags] @ git+https://github.com/ansible/django-ansible-base@${DAB_COMMIT}
GITREQ
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 4. Write VERSION file
# -------------------------------------------------------------------
echo "=> Writing VERSION file (${VERSION})..."
echo "${VERSION}" > "${BUILD_DIR}/VERSION"
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 5. Strip uwsgi from requirements.in
#    The spec file does this in %prep; we mirror so the venv install in
#    the builder stage doesn't try to pip-install uwsgi. The runtime
#    image uses the dnf-installed uwsgi instead.
# -------------------------------------------------------------------
echo "=> Patching requirements (remove uwsgi from requirements.in)..."
sedi '/^uwsgi/d' "${BUILD_DIR}/requirements/requirements.in"
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 6. Extract the Platform UI (aap-ui) from the SAME gateway "-source" wrapper.
#    Strip the Cachi2-wired lockfiles so npm resolves from the public registry.
# -------------------------------------------------------------------
echo "=> Preparing Platform UI source from the gateway -source wrapper..."
AAP_UI_SRC="${GATEWAY_WRAPPER}/${AAP_UI_SOURCE_SUBPATH}"
if [ ! -d "${AAP_UI_SRC}/platform" ]; then
    echo "   ERROR: no aap-ui/platform at ${AAP_UI_SOURCE_SUBPATH} in the gateway -source"
    exit 1
fi
rm -rf "${AAP_UI_DIR}"; mkdir -p "${AAP_UI_DIR}"
cp -a "${AAP_UI_SRC}/." "${AAP_UI_DIR}/"
find "${AAP_UI_DIR}" -name 'package-lock.json' -not -path '*/node_modules/*' -delete
echo "   aap-ui: stripped Cachi2 lockfiles (will resolve from public npm)"
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 7. Copy platform-ui source into Docker build context
# -------------------------------------------------------------------
echo "=> Copying platform-ui source into Docker build context..."
rm -rf "${BUILD_DIR}/aap-ui"
cp -a "${AAP_UI_DIR}" "${BUILD_DIR}/aap-ui"
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 8. Debrand platform UI (custom assets + remove trademarks)
# -------------------------------------------------------------------
echo "=> Debranding platform UI..."
PLATFORM_DIR="${BUILD_DIR}/aap-ui/platform"
DEBRAND_DIR="${SCRIPT_DIR}/debrand"

# 8.0 Derive the upstream vendor token from the vendor's OWN distributed
# source instead of hardcoding it here — this keeps the published build
# script free of the trademark literal. The shared AboutModal ships a
# "Copyright {{fullYear}} <VENDOR>, Inc." line; a structural capture pulls
# <VENDOR> into shell vars used by every debrand replacement below.
ABOUTMODAL="${BUILD_DIR}/aap-ui/frontend/common/AboutModal.tsx"
VENDOR="$(grep -ohE 'Copyright \{\{fullYear\}\} .+, Inc\.' "${ABOUTMODAL}" 2>/dev/null \
    | head -1 | sed -E 's/^Copyright \{\{fullYear\}\} (.+), Inc\..*/\1/')"
if [ -z "${VENDOR}" ]; then
    echo "   ERROR: could not derive vendor token from ${ABOUTMODAL} (upstream layout changed?)."
    echo "          Refusing to run debrand replacements with an empty token."
    exit 1
fi
VENDOR_CAMEL="$(printf '%s' "${VENDOR}" | tr -d ' ')"                              # spaces removed
VENDOR_SLUG="$(printf '%s' "${VENDOR}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"  # lowercased, no spaces
VENDOR_USCORE="$(printf '%s' "${VENDOR}" | tr ' ' '_')"                            # spaces -> underscores
echo "   (derived vendor token: ${#VENDOR} chars)"

# 8a. Overwrite the platform brand assets IN PLACE with debranded ones.
# Renamed the "aap-logo.svg" set to platform-logo*.svg + platform-icon.svg
# (masthead imports platform-logo.svg + platform-icon.svg; login imports
# platform-logo-login.svg; About + favicon reference them by URL). Overwriting the
# files keeps every import/URL working with no source edits — no rename needed.
#   - platform-logo.svg (masthead, ?react inline): currentColor -> adapts to theme
#   - platform-logo-login.svg (login, forced color:white): currentColor renders white
#   - platform-logo-white.svg (dark-theme <img>): explicit white
#   - platform-icon.svg (collapsed nav + favicon): neutral community icon
for sub in assets public; do
    dir="${PLATFORM_DIR}/${sub}"
    [ -f "${dir}/platform-logo.svg" ]       && cp "${DEBRAND_DIR}/ap-logo.svg"        "${dir}/platform-logo.svg"
    [ -f "${dir}/platform-logo-white.svg" ] && cp "${DEBRAND_DIR}/ap-logo-white.svg"  "${dir}/platform-logo-white.svg"
    [ -f "${dir}/platform-logo-login.svg" ] && cp "${DEBRAND_DIR}/ap-logo.svg"        "${dir}/platform-logo-login.svg"
    [ -f "${dir}/platform-icon.svg" ]       && cp "${DEBRAND_DIR}/community-icon.svg" "${dir}/platform-icon.svg"
done
# About modal uses <img src> (currentColor does NOT apply to <img>), so dark theme
# needs an explicitly-white asset served from public/.
cp "${DEBRAND_DIR}/ap-logo-white.svg" "${PLATFORM_DIR}/public/platform-logo-white.svg"

# 8b. PlatformMasthead.tsx — pair the community icon with the masthead wordmark +
# repoint the vendor docs link. The logo (platform-logo.svg) and collapsed icon
# (platform-icon.svg) assets are handled by the 8a overwrite; PlatformIcon is already
# imported, so we just wrap the expanded wordmark with it (parity with the login and
# with the vendor lockup, which pairs an icon with the product name).
# Render the masthead brand as the community icon + an HTML text wordmark (explicit
# font-size). Two reasons we don't reuse the SVG/?react here:
#   - the wide 1-line SVG wordmark was width-constrained by MastheadLogo -> tiny, so
#     HTML text (not width-scaled) gives a controlled, readable size;
#   - the ?react/svgr icon import strips the SVG's fill colors (themed via
#     currentColor) -> the community icon vanished against the masthead, so we point
#     an <img> at the served /platform-icon.svg (colors intact, no svgr).
# ("Automation Platform" is our neutral product name.)
sedi "s|<PlatformLogo style={{ height: 48 }} />|<span style={{ display: 'flex', alignItems: 'center', gap: '10px' }}><img src=\"/platform-icon.svg\" alt=\"\" style={{ height: 30, width: 30 }} /><span style={{ fontSize: '22px', fontWeight: 600, whiteSpace: 'nowrap' }}>Automation Platform</span></span>|" \
    "${PLATFORM_DIR}/main/PlatformMasthead.tsx"
# Repoint the docs link (matched structurally on any access.<host>.com/documentation URL).
# Exclude the template-literal/JSX terminators (backtick, } ) from the char class so the
# greedy match stops at the URL boundary — the link lives inside a `...` template literal.
sedi -E 's|https://access\.[a-z]+\.com/documentation/[^"'"'"' `}]*|https://docs.ansible.com/automation-controller/latest/html/userguide/index.html|' \
    "${PLATFORM_DIR}/main/PlatformMasthead.tsx"

# 8c. PlatformAbout.tsx — rewrite with brand logo fix, product name, copyright, gateway version
cat > "${PLATFORM_DIR}/main/PlatformAbout.tsx" << 'ABOUT_TSX'
import { PageSettingsContext, usePageDialog } from '@ansible/ansible-ui-framework';
import { awxAPI } from '@ansible/awx-ui/common/api/awx-utils';
import { useGet } from '@ansible/common-ui/crud/useGet';
import { edaAPI } from '@ansible/eda-ui/common/eda-utils';
import { hubAPI } from '@ansible/hub-ui/common/api/formatPath';
import { gatewayAPI } from '../utils/gateway-api-utils';
import { AboutModal, Content } from '@patternfly/react-core';
import { t } from 'i18next';
import React, { useContext } from 'react';

export const PlatformAbout: React.FunctionComponent<{
  platformVersion?: string;
}> = ({ platformVersion }) => {
  const gatewayInfo = useGet<{ version: string }>(gatewayAPI`/ping/`);
  const awxInfo = useGet<{ version: string }>(awxAPI`/ping/`);
  const hubInfo = useGet<{ galaxy_ng_version: string }>(hubAPI`/`);
  const edaInfo = useGet<{ version: string }>(edaAPI`/config/`);

  const gatewayVersion = gatewayInfo.data?.version;
  const awxVersion = awxInfo.data?.version;
  const hubVersion = hubInfo.data?.galaxy_ng_version;
  const edaVersion = edaInfo.data?.version;
  const [settings] = useContext(PageSettingsContext);

  const [_, setPageDialog] = usePageDialog();
  return (
    <AboutModal
      isOpen={true}
      onClose={(_e: React.MouseEvent<Element, MouseEvent> | KeyboardEvent | MouseEvent) =>
        setPageDialog(undefined)
      }
      productName={t('Version {{version}}', { version: platformVersion })}
      trademark={`${new Date().getFullYear()}`}
      brandImageAlt={t('Brand Logo')}
      brandImageSrc={
        settings?.activeTheme === 'dark' ? '/platform-logo-white.svg' : '/platform-logo.svg'
      }
    >
      <Content>
        <Content component="dl">
          {gatewayVersion && (
            <>
              <Content component="dt">{t('Gateway Version')}</Content>
              <Content component="dd">{gatewayVersion}</Content>
            </>
          )}
          {awxVersion && (
            <>
              <Content component="dt">{t('AWX Version')}</Content>
              <Content component="dd">{awxVersion}</Content>
            </>
          )}
          {edaVersion && (
            <>
              <Content component="dt">{t('EDA Version')}</Content>
              <Content component="dd">{edaVersion}</Content>
            </>
          )}
          {hubVersion && (
            <>
              <Content component="dt">{t('Galaxy Version')}</Content>
              <Content component="dd">{hubVersion}</Content>
            </>
          )}
        </Content>
      </Content>
    </AboutModal>
  );
};
ABOUT_TSX

# 8d. PlatformLogin.tsx — pair a neutral community icon with the login wordmark
# (our 8a overwrite left the login showing only the "Automation Platform" text).
# Use an <img> pointing at the served /platform-icon.svg (community icon after 8a)
# rather than a ?react import: svgr strips the SVG fill colors (themed via
# currentColor) and the icon disappears, whereas <img> keeps the file's own colors.
# Also debrand the brand-image alt text.
sedi "s|<Logo style={{ color: 'white' }} />|<span style={{ display: 'flex', alignItems: 'center', gap: '20px' }}><img src=\"/platform-icon.svg\" alt=\"\" style={{ height: 64, width: 64 }} /><Logo style={{ color: 'white' }} /></span>|" \
    "${PLATFORM_DIR}/main/PlatformLogin.tsx"
sedi "s|process.env.PRODUCT as unknown as string|'Automation Platform'|" \
    "${PLATFORM_DIR}/main/PlatformLogin.tsx"

# 8e. index.html — debrand the <title> (structural product-name collapse). The
# favicon reference (href="/platform-icon.svg") is left as-is; 8a overwrites that
# asset file with the neutral community icon.
sedi -E 's|<title>([A-Z][a-z]+ )+Automation Platform</title>|<title>Automation Platform</title>|' \
    "${PLATFORM_DIR}/index.html"

# Product-name normalizer: collapse a run of leading Capitalized brand words
# immediately before "Automation Platform" down to just "Automation Platform"
# (e.g. "<Vendor> <Brand> Automation Platform" -> "Automation Platform"). Purely
# structural — carries neither the vendor nor the full product-name literal.
debrand_product_name() {
    sedi -E 's|([A-Z][a-z]+ )+Automation Platform|Automation Platform|g' "$1"
}

# 8f. SubscriptionWizard.tsx — normalize product name + vendor references
if [ -f "${PLATFORM_DIR}/settings/SubscriptionWizard.tsx" ]; then
    debrand_product_name "${PLATFORM_DIR}/settings/SubscriptionWizard.tsx"
    sedi "s|${VENDOR} Satellite|Satellite|g" \
        "${PLATFORM_DIR}/settings/SubscriptionWizard.tsx"
    sedi "s|${VENDOR} |Community |g" \
        "${PLATFORM_DIR}/settings/SubscriptionWizard.tsx"
fi

# 8g. PlatformOverview.tsx — normalize welcome text product name
if [ -f "${PLATFORM_DIR}/overview/PlatformOverview.tsx" ]; then
    debrand_product_name "${PLATFORM_DIR}/overview/PlatformOverview.tsx"
fi

# 8h. PlatformUserForm.tsx — normalize product-name references
if [ -f "${PLATFORM_DIR}/access/users/components/PlatformUserForm.tsx" ]; then
    debrand_product_name "${PLATFORM_DIR}/access/users/components/PlatformUserForm.tsx"
fi

# 8i. AboutModal.tsx (shared) — strip the vendor copyright (matched structurally
# on "Copyright {{fullYear}} <anything>, Inc.")
if [ -f "${ABOUTMODAL}" ]; then
    sedi -E 's|Copyright \{\{fullYear\}\} .+, Inc\.|{{fullYear}}|' \
        "${ABOUTMODAL}"
fi

# 8j. Strip the platform/overview/quickstarts feature entirely.
# Quickstart files ship icons + AAP-flavored walkthroughs we don't
# want in our community build. Removing the directory is straightforward;
# the harder part is unhooking 6 import sites that reference it. Strategy:
# stub `useQuickStarts` to `() => []` so all `quickStarts.length > 0`
# conditionals short-circuit to false, then remove the obvious
# unconditional UI bindings (nav menu entry, masthead dropdown,
# PlatformMain provider wrapper, vite vendor chunk).
echo "   Stripping quickstarts feature..."
rm -rf "${PLATFORM_DIR}/overview/quickstarts"

# 8j.1 — replace useQuickStarts imports with inline stub
#        (covers the 2 import sites: useManagedPlatformOverview + PlatformMasthead)
sedi "s|import { useQuickStarts } from './quickstarts/useQuickStarts';|const useQuickStarts = () => [];|" \
    "${PLATFORM_DIR}/overview/useManagedPlatformOverview.tsx"
sedi "s|import { useQuickStarts } from '../overview/quickstarts/useQuickStarts';|const useQuickStarts = () => [];|" \
    "${PLATFORM_DIR}/main/PlatformMasthead.tsx"

# 8j.2 — strip QuickStartProvider wrapper from PlatformMain.tsx (multi-line)
python3 -c "
import re
f = '${PLATFORM_DIR}/main/PlatformMain.tsx'
content = open(f).read()
# Drop 'import { QuickStartProvider } from ...' line(s) wholesale
content = re.sub(r'^.*QuickStartProvider.*\n', '', content, flags=re.MULTILINE)
open(f, 'w').write(content)
"

# 8j.3 — remove QuickStarts nav entry block + reorder block from usePlatformNavigation.tsx
# UI 2.6.8 wraps the nav item in `if (!managedCloudInstall) { navigationItems.push({...}); }`
# rather than a bare object literal — earlier regex-based approach silently no-op'd.
# Switch to anchored exact-string replace + assertion so future drift fails LOUDLY.
python3 -c "
import re
f = '${PLATFORM_DIR}/main/usePlatformNavigation.tsx'
content = open(f).read()

nav_block = '''    // QuickStarts
    if (!managedCloudInstall) {
      navigationItems.push({
        id: PlatformRoute.QuickStarts,
        label: t('QuickStarts'),
        path: 'quickstarts',
        element: <QuickStartsPage />,
      });
    }
'''
if nav_block not in content:
    raise SystemExit('QuickStarts nav-item anchor not found in usePlatformNavigation.tsx — upstream may have refactored')
content = content.replace(nav_block, '')

reorder_block = '''        const quickstarts = removeNavigationItemById(navigationItems, PlatformRoute.QuickStarts);
        if (quickstarts) {
          navigationItems.push(quickstarts);
        }
'''
if reorder_block not in content:
    raise SystemExit('QuickStarts reorder anchor not found in usePlatformNavigation.tsx — upstream may have refactored')
content = content.replace(reorder_block, '')

# Drop the QuickStartsPage import (now dangling). Path is .../quickstarts/Quickstarts (note casing).
content = re.sub(r'^.*QuickStartsPage.*\n', '', content, flags=re.MULTILINE)

open(f, 'w').write(content)
"

# 8j.4 — drop QuickStarts entry from PlatformRoutes enum
sedi "/QuickStarts = 'platform-quickstarts',/d" \
    "${PLATFORM_DIR}/main/PlatformRoutes.tsx"

# 8j.5 — strip the masthead 'Quick starts' DropdownItem block
python3 -c "
import re
f = '${PLATFORM_DIR}/main/PlatformMasthead.tsx'
content = open(f).read()
content = re.sub(
    r'\s*\{!managedCloudInstall && quickStarts\.length > 0 \?[^}]*?Quick starts[^}]*?\) : null\}\s*\n',
    '\n',
    content,
    flags=re.DOTALL,
)
open(f, 'w').write(content)
"

# 8j.6 — drop pfquickstarts vendor chunk from vite.config.ts (build-time only)
sedi "/pfquickstarts:.*@patternfly\\/quickstarts/d" \
    "${PLATFORM_DIR}/vite.config.ts"

# 8k. PlatformApp.tsx — remove subscription compliance banner (not applicable to community builds)
sedi 's|{subscriptionBanner}||' "${PLATFORM_DIR}/main/PlatformApp.tsx"

# 8l. SubscriptionDetails.tsx — replace with community-friendly read-only page
cat > "${PLATFORM_DIR}/settings/SubscriptionDetails.tsx" << 'SUBDETAILS_TSX'
import {
  LoadingPage,
  PageDetail,
  PageDetails,
  PageHeader,
  PageLayout,
} from '@ansible/ansible-ui-framework';
import { useAwxConfig } from '@ansible/awx-ui/common/useAwxConfig';
import { useTranslation } from 'react-i18next';

export function SubscriptionDetails() {
  const { t } = useTranslation();
  const awxConfig = useAwxConfig();

  if (!awxConfig) {
    return <LoadingPage />;
  }

  const license_info = awxConfig.license_info;

  let license_type = license_info.license_type;
  switch (license_type) {
    case 'enterprise':
      license_type = t('Enterprise');
      break;
    case 'open':
      license_type = t('Open');
      break;
    case 'trial':
      license_type = t('Trial');
      break;
  }

  return (
    <PageLayout>
      <PageHeader title={t('Subscription')} />
      <PageDetails>
        <PageDetail label={t('Subscription type')}>{license_type}</PageDetail>
        <PageDetail label={t('Subscription')}>{license_info.subscription_name}</PageDetail>
      </PageDetails>
    </PageLayout>
  );
}
SUBDETAILS_TSX

# 8m. PlatformSubscription.tsx — skip subscription wizard for community builds
sedi 's/Object\.keys(awxConfig\.license_info)\.length/true/' \
    "${PLATFORM_DIR}/main/PlatformSubscription.tsx"

# 8n. Hide subscription wizard route (keep details page, remove edit route)
sedi "s|element: <SubscriptionWizard onSuccess={() => void navigate('/settings/subscription')} />|element: <SubscriptionDetails />|" \
    "${PLATFORM_DIR}/main/usePlatformNavigation.tsx"

echo "   Done."
echo ""

# -------------------------------------------------------------------
# 8.5 Debrand the Gateway DRF browsable API (Django backend)
# -------------------------------------------------------------------
# Everything above (step 8) debrands the React SPA (aap-ui/platform).
# The Django REST Framework browsable API served at /api/ and its login
# page at /api/gateway/v1/... render from a SEPARATE template tree in the
# gateway backend (aap_gateway_api/templates/rest_framework/) that ships a
# vendor logo + favicon + copyright footer. Debrand it here.
#
# github.com/fitbeard/automation-platform#223 reported the logo, favicon, and
# footer copyright. We additionally repoint the API-guide help link.
# login.html `{% extends 'rest_framework/api.html' %}` and only overrides
# breadcrumbs/content, so fixing api.html covers the login page too.
#
# Backend hybrid-cloud-console references (registered_preferences.py,
# defaults.py, status.py) are FUNCTIONAL integration endpoints/field names,
# NOT browsable-API branding — left alone.
#
# All matches are STRUCTURAL (filenames/attrs/URL host shapes) so this
# script carries no vendor-trademark literal.
echo "=> Debranding Gateway DRF browsable API (Django backend)..."
GW_API_DIR="${BUILD_DIR}/aap_gateway_api"
GW_STATIC_IMAGES="${GW_API_DIR}/static/images"
GW_API_TEMPLATE="${GW_API_DIR}/templates/rest_framework/api.html"

if [ ! -f "${GW_API_TEMPLATE}" ]; then
    echo "   ERROR: ${GW_API_TEMPLATE} not found — gateway source layout changed?"
    exit 1
fi

# 8.5a — ship debranded static assets, then drop the upstream vendor ones
# (globs match the vendor Logo-*.svg / Product_icon-*.png; our ap-logo-white
# + community-icon use different prefixes so they survive the rm).
cp "${DEBRAND_DIR}/ap-logo-white.svg" "${GW_STATIC_IMAGES}/ap-logo-white.svg"
cp "${DEBRAND_DIR}/community-icon.svg" "${GW_STATIC_IMAGES}/community-icon.svg"
rm -f "${GW_STATIC_IMAGES}"/Logo-*.svg "${GW_STATIC_IMAGES}"/Product_icon-*.png

# 8.5b — structural single-line replacements in api.html
#   logo <img src> (images/Logo-*.svg) + its alt, favicon (images/Product_icon-*.png),
#   and the API-guide help link (any https://help.<host>.com/ URL).
sedi -E "s|images/Logo-[A-Za-z0-9_.-]+\.svg|images/ap-logo-white.svg|" \
    "${GW_API_TEMPLATE}"
sedi -E 's|alt="AAP Platform"|alt="Automation Platform"|' \
    "${GW_API_TEMPLATE}"
sedi -E "s|images/Product_icon-[A-Za-z0-9_.-]+\.png|images/community-icon.svg|" \
    "${GW_API_TEMPLATE}"
sedi -E 's|href="https://help\.[a-z]+\.com/"|href="https://docs.ansible.com/"|' \
    "${GW_API_TEMPLATE}"
# Newer source moved the API-guide link to a vendor docs-site URL of the shape
# https://docs.<host>.com/en/documentation/<product-slug>/<ver>/<page>. Repoint
# it structurally (host + /en/documentation/ path shape, no vendor literal) so
# the vendor product-slug (which the residual-branding guard below flags) is gone.
sedi -E 's|href="https://docs\.[a-z]+\.com/en/documentation/[^"]*"|href="https://docs.ansible.com/"|' \
    "${GW_API_TEMPLATE}"

# 8.5c — remove the copyright footer block if present. Matched STRUCTURALLY on
# the <div id="footer"> … </div> wrapper (3 nested divs), not on its text, so no
# vendor literal appears here. The 2.6.20261116 source dropped the footer block
# entirely (no copyright to strip), so its absence is fine — only the vendor
# guard (8.5d) is authoritative about residual branding.
python3 -c "
import re
f = '${GW_API_TEMPLATE}'
content = open(f).read()
pattern = re.compile(r'<div id=\"footer\">.*?</div>\s*</div>\s*</div>\n?', re.DOTALL)
if pattern.search(content):
    open(f, 'w').write(pattern.sub('', content))
    print('   Removed DRF footer block.')
else:
    print('   No DRF footer block present (upstream dropped it) — nothing to strip.')
"

# 8.5d — fail loudly if any vendor token survives (needle built from the
# derived token + its underscore/slug variants; no literal here).
if grep -qiE "${VENDOR}|${VENDOR_USCORE}|${VENDOR_SLUG}" "${GW_API_TEMPLATE}"; then
    echo '   ERROR: residual vendor branding still present in api.html after debrand:'
    grep -niE "${VENDOR}|${VENDOR_USCORE}|${VENDOR_SLUG}" "${GW_API_TEMPLATE}"
    exit 1
fi
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 8.6 Silence "Product Notifications"
# -------------------------------------------------------------------
# The platform UI hook platform/notifications/useRssNotifications.tsx has
# the superuser's browser fetch an Atom announcements feed every 10 min and
# render entries under "Product Notifications" (e.g. an "upgrade to 2.7"
# notice). It only fetches when BOTH gateway settings are truthy:
#   NOTIFICATION_RSS_FEED_ENABLED && NOTIFICATION_RSS_FEED_URL
#
# For a community build we (a) default the feed OFF, and (b) blank the
# hardcoded upstream feed URL so the browser never phones home even if a
# superuser re-enables it (they can still set their own URL — the ENABLED
# pref stays read_only=False). Matches are structural — no upstream endpoint
# literal appears in this script.
echo "=> Silencing product-notification RSS feed..."
GW_PREFS="${GW_API_DIR}/registered_preferences.py"
GW_DEFAULTS="${GW_API_DIR}/defaults.py"

# 8.6a — flip NOTIFICATION_RSS_FEED_ENABLED default True -> False (targeted:
# only the register() block whose preference_name is that pref; a bare
# s/default=True/default=False/ would clobber unrelated prefs).
python3 -c "
f = '${GW_PREFS}'
c = open(f).read()
anchor = '''    preference_name=\"NOTIFICATION_RSS_FEED_ENABLED\",
    required=True,
    default=True,'''
repl = '''    preference_name=\"NOTIFICATION_RSS_FEED_ENABLED\",
    required=True,
    default=False,'''
if anchor not in c:
    raise SystemExit('NOTIFICATION_RSS_FEED_ENABLED default=True anchor not found — upstream may have refactored')
open(f, 'w').write(c.replace(anchor, repl))
"

# 8.6b — blank the feed URL structurally: the defaults.py assignment and the
# getattr fallback in registered_preferences.py (any https:// value → "").
sedi -E 's|(NOTIFICATION_RSS_FEED_URL = )"https://[^"]*"|\1""|' \
    "${GW_DEFAULTS}"
sedi -E 's|(getattr\(settings, "NOTIFICATION_RSS_FEED_URL", )"https://[^"]*"|\1""|' \
    "${GW_PREFS}"

# 8.6c — assert no non-empty feed URL remains on either NOTIFICATION line
if grep -nE 'NOTIFICATION_RSS_FEED_URL.*"https://' "${GW_PREFS}" "${GW_DEFAULTS}"; then
    echo "   ERROR: feed URL still non-empty after silencing (see above)."
    exit 1
fi
echo "   Done."
echo ""

# -------------------------------------------------------------------
# 9. Build the container image
# -------------------------------------------------------------------
BUILDX_ARGS=(
    -f "${SCRIPT_DIR}/Dockerfile"
    --build-arg VERSION="${VERSION}"
    --build-arg SETUPTOOLS_SCM_PRETEND_VERSION="${VERSION}"
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

    echo "=> Building multiarch image and pushing to registry..."
    docker buildx build "${BUILDX_ARGS[@]}" \
        --platform "${PLATFORMS}" \
        --push \
        "${BUILD_DIR}"
elif [ -n "${LOCAL_PLATFORM}" ]; then
    echo "=> Building image for ${LOCAL_PLATFORM} (local)..."
    DOCKER_BUILDKIT=1 docker buildx build "${BUILDX_ARGS[@]}" \
        --platform "${LOCAL_PLATFORM}" \
        --load \
        "${BUILD_DIR}"
else
    echo "=> Building container image for local use..."
    DOCKER_BUILDKIT=1 docker build "${BUILDX_ARGS[@]}" "${BUILD_DIR}"
fi

echo ""
echo "=== Build complete ==="
echo "  Image: ${IMAGE_NAME}:${IMAGE_TAG}"
if [ "${PUSH}" = true ]; then
    echo "  Platforms: ${PLATFORMS}"
    echo "  Pushed to registry."
fi
