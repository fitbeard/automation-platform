#!/usr/bin/env bash
#
# Build AAP Gateway container image from SRPM source.
#
# Sources are downloaded from Red Hat's public FTP and extracted
# fresh each run — no cached `gateway-src/` reuse.
# Only debrand/ stays as a permanent
# directory because we ship custom assets from there.
#
# Pinned versions (SRPM build dates in comments):
#   - automation-gateway:     2.6.20260422-1 (build date 2026-04-22)
#   - automation-platform-ui: 2.6.8-1       (same SRPM AWX uses)
#   - django-ansible-base:    5f6343b9b98c  (latest devel before SRPM cut; override via DAB_COMMIT=...)
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

GATEWAY_SRPM_URL="${GATEWAY_SRPM_URL:-https://ftp.redhat.com/redhat/linux/enterprise/9Base/en/AnsibleAutomationPlatform/SRPMS/automation-gateway-2.6.20260422-1.el9ap.src.rpm}"
GATEWAY_TARBALL_GLOB="aap-gateway-*.tar.gz"
GATEWAY_SRPM_DIR="${GATEWAY_SRPM_DIR:-${SCRIPT_DIR}/gateway-srpm}"

AAP_UI_SRPM_URL="${AAP_UI_SRPM_URL:-https://ftp.redhat.com/redhat/linux/enterprise/9Base/en/AnsibleAutomationPlatform/SRPMS/automation-platform-ui-2.6.8-1.el9ap.src.rpm}"
AAP_UI_TARBALL_GLOB="aap-ui-*.tar.gz"
AAP_UI_SRPM_DIR="${AAP_UI_SRPM_DIR:-${SCRIPT_DIR}/aap-ui-srpm}"
AAP_UI_DIR="${AAP_UI_DIR:-${SCRIPT_DIR}/aap-ui}"

VERSION="${VERSION:-2.6.20260422}"
IMAGE_NAME="${IMAGE_NAME:-quay.io/fitbeard/ansible-platform/gateway}"
IMAGE_TAG="${IMAGE_TAG:-$VERSION}"
BUILD_DIR="${BUILD_DIR:-${SCRIPT_DIR}/gateway-src}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER_NAME="gateway-multiarch"

# Gateway 2.6.20260422 sets EMAIL_ENFORCEMENT_VIA_SERIALIZER = True on
# its User model — DAB at 5f6343b doesn't yet read this flag (the
# email-enforcement signals landed on devel later, 2026-05-06 d5100f6).
# At our pin the flag is set but inert. Gateway's email policy is fully
# enforced in its own _validate_email_change serializer + reverse-sync
# GetOrCreateProcessor regardless of DAB version.
DAB_COMMIT="${DAB_COMMIT:-5f6343b9b98c5e48e7a4dc087bf931cd2bd5f104}"

# --- Pre-flight --------------------------------------------------------------

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

echo "=== AAP Gateway rebuild from SRPM (automation-gateway ${VERSION}) ==="
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
# 2. Download (if missing) + extract gateway SRPM
# -------------------------------------------------------------------
echo "=> Preparing gateway source from SRPM..."
mkdir -p "${GATEWAY_SRPM_DIR}"
GATEWAY_SRPM_FILE="${GATEWAY_SRPM_DIR}/$(basename "${GATEWAY_SRPM_URL}")"
if [ ! -f "${GATEWAY_SRPM_FILE}" ]; then
    echo "   Downloading gateway SRPM..."
    curl -fSL -o "${GATEWAY_SRPM_FILE}" "${GATEWAY_SRPM_URL}"
fi
# Always wipe other SRPM artifacts in this dir from prior versions
find "${GATEWAY_SRPM_DIR}" -maxdepth 1 -name "${GATEWAY_TARBALL_GLOB}" -delete 2>/dev/null || true
echo "   Extracting SRPM..."
(cd "${GATEWAY_SRPM_DIR}" && rpm2cpio "${GATEWAY_SRPM_FILE}" | cpio -idm --quiet 2>/dev/null)
GATEWAY_TARBALL=$(find "${GATEWAY_SRPM_DIR}" -maxdepth 1 -name "${GATEWAY_TARBALL_GLOB}" | head -1)
if [ -z "${GATEWAY_TARBALL}" ]; then
    echo "   ERROR: Could not find ${GATEWAY_TARBALL_GLOB} in extracted SRPM"
    exit 1
fi
echo "   Found: $(basename "${GATEWAY_TARBALL}")"
mkdir -p "${BUILD_DIR}"
tar xzf "${GATEWAY_TARBALL}" -C "${BUILD_DIR}" --strip-components=1
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
# 6. Download (if missing) + extract Platform UI SRPM
# -------------------------------------------------------------------
echo "=> Preparing Platform UI source from SRPM..."
mkdir -p "${AAP_UI_SRPM_DIR}"
UI_SRPM_FILE="${AAP_UI_SRPM_DIR}/$(basename "${AAP_UI_SRPM_URL}")"
if [ ! -f "${UI_SRPM_FILE}" ]; then
    echo "   Downloading AAP UI SRPM..."
    curl -fSL -o "${UI_SRPM_FILE}" "${AAP_UI_SRPM_URL}"
fi
find "${AAP_UI_SRPM_DIR}" -maxdepth 1 -name "${AAP_UI_TARBALL_GLOB}" -delete 2>/dev/null || true
echo "   Extracting SRPM..."
(cd "${AAP_UI_SRPM_DIR}" && rpm2cpio "${UI_SRPM_FILE}" | cpio -idm --quiet 2>/dev/null)
UI_TARBALL=$(find "${AAP_UI_SRPM_DIR}" -maxdepth 1 -name "${AAP_UI_TARBALL_GLOB}" | head -1)
if [ -z "${UI_TARBALL}" ]; then
    echo "   ERROR: Could not find ${AAP_UI_TARBALL_GLOB} in extracted SRPM"
    exit 1
fi
echo "   Found: $(basename "${UI_TARBALL}")"
mkdir -p "${AAP_UI_DIR}"
tar xzf "${UI_TARBALL}" -C "${AAP_UI_DIR}" --strip-components=1
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
# 8. Debrand platform UI (custom assets + remove Red Hat / AAP trademarks)
# -------------------------------------------------------------------
echo "=> Debranding platform UI..."
PLATFORM_DIR="${BUILD_DIR}/aap-ui/platform"
DEBRAND_DIR="${SCRIPT_DIR}/debrand"

# 8a. Replace and rename logo/icon SVG assets (aap-* → ap-*, redhat-* → community-*)
cp "${DEBRAND_DIR}/ap-logo.svg"        "${PLATFORM_DIR}/assets/ap-logo.svg"
cp "${DEBRAND_DIR}/ap-logo-white.svg"  "${PLATFORM_DIR}/assets/ap-logo-white.svg"
cp "${DEBRAND_DIR}/community-icon.svg" "${PLATFORM_DIR}/assets/community-icon.svg"
# public/ files are served as-is by Vite (no hash) — needed for runtime URL references
cp "${DEBRAND_DIR}/ap-logo.svg"        "${PLATFORM_DIR}/public/ap-logo.svg"
cp "${DEBRAND_DIR}/ap-logo-white.svg"  "${PLATFORM_DIR}/public/ap-logo-white.svg"
cp "${DEBRAND_DIR}/community-icon.svg" "${PLATFORM_DIR}/public/community-icon.svg"
# Remove old-named files so they don't end up in the build
rm -f "${PLATFORM_DIR}/assets/aap-logo.svg" "${PLATFORM_DIR}/assets/aap-logo-white.svg" "${PLATFORM_DIR}/assets/redhat-icon.svg"
rm -f "${PLATFORM_DIR}/public/aap-logo.svg" "${PLATFORM_DIR}/public/redhat-icon.svg"

# 8b. PlatformMasthead.tsx — rename imports, remove Red Hat icon, fix docs link
sedi "s|from '../assets/aap-logo.svg?react'|from '../assets/ap-logo.svg?react'|" \
    "${PLATFORM_DIR}/main/PlatformMasthead.tsx"
sedi "s|import RedHatIcon from '../assets/redhat-icon.svg?react';|// RedHatIcon removed (debranded)|" \
    "${PLATFORM_DIR}/main/PlatformMasthead.tsx"
sedi 's|{!isSmOrLarger && <RedHatIcon style={{ height: 38, width: 38 }} />}||' \
    "${PLATFORM_DIR}/main/PlatformMasthead.tsx"
sedi 's|https://access.redhat.com/documentation/en-us/red_hat_ansible_automation_platform|https://docs.ansible.com/automation-controller/latest/html/userguide/index.html|' \
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
        settings?.activeTheme === 'dark' ? '/ap-logo-white.svg' : '/ap-logo.svg'
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

# 8d. PlatformLogin.tsx — rename import, add community icon, change alt text
sedi "s|from '../assets/aap-logo.svg?react'|from '../assets/ap-logo.svg?react'|" \
    "${PLATFORM_DIR}/main/PlatformLogin.tsx"
sedi "s|from '../assets/ap-logo.svg?react';|from '../assets/ap-logo.svg?react';\nimport CommunityIcon from '../assets/community-icon.svg?react';|" \
    "${PLATFORM_DIR}/main/PlatformLogin.tsx"
sedi "s|<AAPLogo style={{ height: 64, color: 'white' }} />|<span style={{ display: 'flex', alignItems: 'center', gap: '12px' }}><CommunityIcon style={{ height: 52, width: 52 }} /><AAPLogo style={{ height: 64, color: 'white' }} /></span>|" \
    "${PLATFORM_DIR}/main/PlatformLogin.tsx"
sedi "s|process.env.PRODUCT as unknown as string|'Ansible Platform'|" \
    "${PLATFORM_DIR}/main/PlatformLogin.tsx"

# 8e. index.html — title and favicon reference
sedi 's|href="/redhat-icon.svg"|href="/community-icon.svg"|' \
    "${PLATFORM_DIR}/index.html"
sedi 's|<meta charset="UTF-8" />|<meta charset="UTF-8" />\n    <title>Ansible Platform</title>|' \
    "${PLATFORM_DIR}/index.html"

# 8f. SubscriptionWizard.tsx — replace Red Hat references
if [ -f "${PLATFORM_DIR}/settings/SubscriptionWizard.tsx" ]; then
    sedi 's|Red Hat Ansible Automation Platform|Ansible Platform|g' \
        "${PLATFORM_DIR}/settings/SubscriptionWizard.tsx"
    sedi 's|Red Hat Satellite|Satellite|g' \
        "${PLATFORM_DIR}/settings/SubscriptionWizard.tsx"
    sedi 's|Red Hat |Community |g' \
        "${PLATFORM_DIR}/settings/SubscriptionWizard.tsx"
fi

# 8g. PlatformOverview.tsx — replace welcome text
if [ -f "${PLATFORM_DIR}/overview/PlatformOverview.tsx" ]; then
    sedi 's|Ansible Automation Platform|Ansible Platform|g' \
        "${PLATFORM_DIR}/overview/PlatformOverview.tsx"
fi

# 8h. PlatformUserForm.tsx — replace any AAP references
if [ -f "${PLATFORM_DIR}/access/users/components/PlatformUserForm.tsx" ]; then
    sedi 's|Ansible Automation Platform|Ansible Platform|g' \
        "${PLATFORM_DIR}/access/users/components/PlatformUserForm.tsx"
fi

# 8i. AboutModal.tsx (shared) — replace copyright
if [ -f "${BUILD_DIR}/aap-ui/frontend/common/AboutModal.tsx" ]; then
    sedi 's|Copyright {{fullYear}} Red Hat, Inc.|{{fullYear}}|' \
        "${BUILD_DIR}/aap-ui/frontend/common/AboutModal.tsx"
fi

# 8j. Strip the platform/overview/quickstarts feature entirely.
# Quickstart files ship Red Hat icons + AAP-flavored walkthroughs we don't
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
# gateway backend (aap_gateway_api/templates/rest_framework/) that ships
# Red Hat logo + favicon + copyright. Debrand it here.
#
# github.com/fitbeard/ansible-platform#223 reported the logo, favicon, and
# footer copyright. We additionally fix the help link (help.redhat.com).
# login.html `{% extends 'rest_framework/api.html' %}` and only overrides
# breadcrumbs/content, so fixing api.html covers the login page too.
#
# Backend console.redhat.com references (registered_preferences.py,
# defaults.py, status.py) are FUNCTIONAL integration endpoints/field names
# for the RH Hybrid Cloud Console, NOT browsable-API branding — left alone.
echo "=> Debranding Gateway DRF browsable API (Django backend)..."
GW_API_DIR="${BUILD_DIR}/aap_gateway_api"
GW_STATIC_IMAGES="${GW_API_DIR}/static/images"
GW_API_TEMPLATE="${GW_API_DIR}/templates/rest_framework/api.html"

if [ ! -f "${GW_API_TEMPLATE}" ]; then
    echo "   ERROR: ${GW_API_TEMPLATE} not found — gateway source layout changed?"
    exit 1
fi

# 8.5a — ship debranded static assets into the gateway static dir, drop RH ones
cp "${DEBRAND_DIR}/ap-logo-white.svg" "${GW_STATIC_IMAGES}/ap-logo-white.svg"
cp "${DEBRAND_DIR}/community-icon.svg" "${GW_STATIC_IMAGES}/community-icon.svg"
rm -f "${GW_STATIC_IMAGES}/Logo-Red_Hat-Ansible_Automation_Platform-A-Standard-RGB.svg" \
      "${GW_STATIC_IMAGES}/Product_icon-Red_Hat-Ansible_Automation_Platform-RGB.png"

# 8.5b — single-line replacements in api.html (logo src+alt, favicon, help link)
sedi "s|images/Logo-Red_Hat-Ansible_Automation_Platform-A-Standard-RGB.svg|images/ap-logo-white.svg|" \
    "${GW_API_TEMPLATE}"
sedi 's|alt="AAP Platform"|alt="Ansible Platform"|' \
    "${GW_API_TEMPLATE}"
sedi "s|images/Product_icon-Red_Hat-Ansible_Automation_Platform-RGB.png|images/community-icon.svg|" \
    "${GW_API_TEMPLATE}"
sedi 's|href="https://help.redhat.com/"|href="https://docs.ansible.com/"|' \
    "${GW_API_TEMPLATE}"

# 8.5c — remove the Red Hat copyright footer block (multi-line; anchor-guarded)
python3 -c "
f = '${GW_API_TEMPLATE}'
content = open(f).read()
footer = '''<div id=\"footer\">
  <div class=\"container\">
    <div class=\"footer-copyright\">
      Copyright &copy; 2024 <a href=\"http://www.redhat.com\" target=\"_blank\" rel=\"noopener\">Red Hat</a>, Inc. All Rights Reserved.
    </div>
  </div>
</div>
'''
if footer not in content:
    raise SystemExit('DRF footer copyright anchor not found in api.html — upstream may have refactored')
content = content.replace(footer, '')
open(f, 'w').write(content)
"

# 8.5d — fail loudly if any Red Hat branding survives in the template
if grep -qiE 'Red_Hat|redhat\.com|Red Hat|AAP Platform' "${GW_API_TEMPLATE}"; then
    echo '   ERROR: residual Red Hat branding still present in api.html after debrand:'
    grep -niE 'Red_Hat|redhat\.com|Red Hat|AAP Platform' "${GW_API_TEMPLATE}"
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
