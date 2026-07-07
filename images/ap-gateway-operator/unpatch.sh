#!/usr/bin/env bash
#
# Inverse-downstreamify for gateway-operator src/.
#
# Downstream applies a `downstreamify.sh` to most upstream operators before
# bundling. For awx/eda/galaxy/ai-connect we work directly against the
# upstream public repos and never touch downstreamify (so we naturally
# get upstream kind/group names like AWX, EDA, AutomationHub, etc.).
#
# Gateway-operator has NO public upstream — the bundle IS the source. It
# also assumes its sub-component CRs were ALSO downstreamified (e.g., it
# expects to create `AutomationController` / `automationcontroller.ansible.com`
# CRs, the renamed-by-RH form of upstream `AWX` / `awx.ansible.com`).
# Since our awx-operator stays upstream, we have to UNDO
# downstreamify on the gateway-operator side.
#
# This script mirrors the shape of downstreamify.sh — sed-based
# global identifier substitutions across the role/template tree. We use
# sed here (instead of patches/*.patch + patch.sh) because:
#
#   - The change is a pure bulk rename, idempotent, file-location-agnostic
#   - It survives bundle updates: a future `2.6-712` bundle that adds new
#     files mentioning AutomationController gets renamed automatically;
#     a literal git patch would silently miss them
#   - One file describing the whole delta is easier to audit than a
#     200-line diff that says the same thing
#
# Surgical changes (real bug fixes, behavior tweaks) DO get authored as
# patches/*.patch and applied by patch.sh — sed isn't the right tool for
# context-sensitive diffs.
#
# Transformations applied here:
#
#   1. AWX kind/group inverse-rename — gateway role expects downstream
#      "AutomationController" / "automationcontroller.ansible.com". Our
#      awx-operator keeps upstream "AWX" / "awx.ansible.com". Flip back.
#      Sub-resources (AutomationControllerBackup, AutomationControllerRestore)
#      are handled automatically by the same prefix substitution.
#
# Future transformations (Hub/Galaxy) will be added
# when those sub-operator integrations are wired up.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"

if [[ ! -d "$SRC_DIR" ]]; then
    echo "ERROR: $SRC_DIR not found — run build.sh first" >&2
    exit 1
fi

cd "$SRC_DIR"

# --- 1. Dockerfile USER non-numeric -> numeric ------------------------------
# Upstream Dockerfile ends with `USER ansible` (string username). With
# `runAsNonRoot: true` on the pod (which manager.yaml sets), kubelet rejects
# the container start: "image has non-numeric user (ansible), cannot verify
# user is non-root". The `ansible` user is UID 1001 in the base image; pin
# it numerically so kubelet can verify without resolving /etc/passwd inside
# the image. Also more resistant to base-image USER changes.

echo "==> Dockerfile: USER ansible -> USER 1001"
sed -i.bak 's/^USER ansible$/USER 1001/' ./Dockerfile
rm -f ./Dockerfile.bak

# --- 2. Local-pull friendliness in manager.yaml -----------------------------
# Upstream src/config/manager/manager.yaml hardcodes:
#   imagePullPolicy: Always   -> won't use locally-loaded kind images
#   imagePullSecrets:
#     - name: <vendor>-operators-pull-secret   -> not present on plain k8s
# Flip both so `kind load docker-image` works and there's no missing secret.
# The pull-secret line is matched structurally (any *-operators-pull-secret).

echo "==> manager.yaml: imagePullPolicy Always -> IfNotPresent, drop operators pull-secret, ANSIBLE_VERBOSITY 2 -> 0, RELATED_IMAGE_GATEWAY/_PROXY -> public"
sed -i.bak \
    -e 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/' \
    -e '/^      imagePullSecrets:$/,/^        - name: [a-z-]*operators-pull-secret$/d' \
    -e "/name: ANSIBLE_VERBOSITY/{n;s/value: '2'/value: '0'/;}" \
    -e "/name: RELATED_IMAGE_GATEWAY$/{n;s|value: .*|value: quay.io/fitbeard/automation-platform/gateway:2.6.20260422|;}" \
    -e "/name: RELATED_IMAGE_GATEWAY_PROXY$/{n;s|value: .*|value: docker.io/envoyproxy/envoy:v1.34-latest|;}" \
    ./config/manager/manager.yaml
rm -f ./config/manager/manager.yaml.bak

# --- 3. Surface rename: AAP -> AP (Automation Platform) ------------------------
# The operator's deeply-internal logic (CRD group `aap.ansible.com`, kind
# `AnsibleAutomationPlatform`, role dir `ansibleautomationplatform`, var
# names `combined_aap`, etc.) keeps the AAP branding because renaming
# them is invasive and high-risk. But on the SURFACE — image name,
# kustomize namePrefix, generated resource names — we drop the extra "A"
# and use AP. The user-visible naming becomes consistent with our other
# rebuild artifacts.

echo "==> Surface AAP -> AP rename"
echo "    namePrefix in kustomize: aap-gateway-operator- -> ap-gateway-operator-"

sed -i.bak 's/^namePrefix: aap-gateway-operator-/namePrefix: ap-gateway-operator-/' \
    ./config/default/kustomization.yaml
rm -f ./config/default/kustomization.yaml.bak

# --- 4. Cross-namespace gateway URL FQDN ------------------------------------
# vars/main.yml builds extra_settings injected into AWX/EDA configmaps with
# bare-hostname gateway URLs (ANSIBLE_BASE_JWT_KEY, RESOURCE_SERVER.URL,
# etc.). Bare 'http://{{ name }}' relies on AWX/EDA living in the SAME
# namespace as the gateway service — fragile across namespace splits.
#
# Rewrite to FQDN form, keeping the SAME service name. The bare-hostname
# 'aap' resolves to the gateway's envoy-front service (port 8000), which
# is the architecturally correct entry point for AWX/EDA server-side
# calls — they get the same path-prefix routing + auth treatment as
# browser traffic. Don't substitute to 'aap-api' (uwsgi-direct, bypasses
# envoy) — that's a different service and changes routing semantics.
# (Patch 0004 uses '-api' for ansible.platform.service_node, which is
# specifically a direct gateway API call; different use case.)
#
# Pattern matches bare-hostname URLs only (not '...-controller-service'
# etc.) by anchoring on a closing string quote (' or ") right after the
# template expression.

echo "==> vars/main.yml: bare-hostname gateway URLs -> FQDN (envoy front, same service name)"
sed -i.bak -E "
s|http://\{\{ ansible_operator_meta\.name \}\}'|http://{{ ansible_operator_meta.name }}.{{ ansible_operator_meta.namespace }}.svc.cluster.local'|g
s|http://\{\{ ansible_operator_meta\.name \}\}\"|http://{{ ansible_operator_meta.name }}.{{ ansible_operator_meta.namespace }}.svc.cluster.local\"|g
" ./roles/ansibleautomationplatform/vars/main.yml
rm -f ./roles/ansibleautomationplatform/vars/main.yml.bak

# --- 5. AWX kind/group inverse-rename ---------------------------------------

echo "==> AWX kind/group inverse-rename"
echo "    AutomationController[Backup|Restore] -> AWX[Backup|Restore]"
echo "    automationcontroller.ansible.com -> awx.ansible.com"

# All .yml/.yaml/.j2 files under roles/ + RBAC.
# `sed -i.bak` is Mac/BSD-portable (GNU sed accepts it too); we delete
# the .bak files immediately after.
find ./roles ./config/rbac -type f \( -name '*.yml' -o -name '*.yaml' -o -name '*.j2' \) \
    -exec sed -i.bak -E '
        s/AutomationController/AWX/g;
        s/automationcontroller\.ansible\.com/awx.ansible.com/g;
        s/automationcontrollerbackups/awxbackups/g;
        s/automationcontrollerrestores/awxrestores/g;
        s/automationcontrollers/awxs/g;
        s/automationcontroller([^a-z])/awx\1/g;
    ' {} \;
find ./roles ./config/rbac -type f -name '*.bak' -delete

# --- 6. MCP kind/group inverse-rename ---------------------------------------
# Same idea as section 5 but for MCP. Downstreamify renames the
# upstream `AnsibleMCPConnect` / `mcpconnect.ansible.com` to downstream
# `AnsibleMCPServer` / `mcpserver.ansible.com`, and gateway-operator's
# bundle source carries those downstream-renamed references in its role
# var files + RBAC + CSV.
#
# Our MCP operator (build-operator-mcp/) stays upstream-pure: keeps
# `AnsibleMCPConnect` / `mcpconnect.ansible.com`. Flip gateway-operator
# back so its reconcile creates / watches the upstream-named CRs.
#
# Pattern same as section 5: bulk substitution across roles/ + config/rbac/.
# Survives bundle bumps that introduce new MCP references.

echo "==> MCP kind/group inverse-rename"
echo "    AnsibleMCPServer -> AnsibleMCPConnect"
echo "    mcpserver.ansible.com -> mcpconnect.ansible.com"
echo "    ansiblemcpservers -> ansiblemcpconnects"

find ./roles ./config/rbac -type f \( -name '*.yml' -o -name '*.yaml' -o -name '*.j2' \) \
    -exec sed -i.bak -E '
        s/AnsibleMCPServer/AnsibleMCPConnect/g;
        s/mcpserver\.ansible\.com/mcpconnect.ansible.com/g;
        s/ansiblemcpservers/ansiblemcpconnects/g;
    ' {} \;
find ./roles ./config/rbac -type f -name '*.bak' -delete

echo "==> unpatch.sh complete"
