# Automation Platform

Automation Platform is an unofficial, open-source build of well know IaC platform.
It brings together the controller, Event-Driven Ansible, Gateway,
execution environments, operators, Helm charts, and supporting
automation needed to run the platform without depending on a single deployment
model.

The project originally started as `awx-without-k8s`, focused on running
[AWX](https://github.com/ansible/awx) on ordinary hosts with Docker Compose.
That history is still visible in the standalone AWX path, but the repository is now
about the whole platform: AWX/controller, EDA, Gateway, container image rebuilds,
Kubernetes operators, Helm charts, MCP support, and Ansible modules for platform
API configuration.

This repository is expected to live at
`https://github.com/fitbeard/automation-platform`. The Ansible Galaxy collection
metadata is still published as `fitbeard.awx`.

> This is an unofficial project. It is not affiliated with or supported by downstream
> product company, and the demo secrets, certificates, and keys are for test environments
> only.

## Screenshots

![Automation Platform gateway overview](https://github.com/user-attachments/assets/892690bb-0fc1-44a7-844f-605a8bc4d144)

![Automation Platform service view](https://github.com/user-attachments/assets/e2bfa50f-36b1-4644-8c7d-d56d9b6092e0)

![Automation Platform controller view](https://github.com/user-attachments/assets/caaad00e-e62f-4e25-af39-7d17c7c732a7)

## What is included

- Docker Compose based Ansible roles for AWX, EDA, Gateway, HAProxy, Docker,
  Root CA, and AWX settings.
- Demo inventories and playbooks for full Gateway mode, AWX standalone mode,
  and EDA standalone mode.
- Rebuilt container image definitions for AWX, AWX EE, EDA, EDA decision
  environment, Gateway, MCP server, and several operators.
- Helm charts for AWX, EDA, Gateway, AWX resource, and MCP operators.

## Repository layout

| Path | Purpose |
| --- | --- |
| `roles/awx` | Installs and upgrades AWX with Docker Compose, nginx, Redis, Postgres, TLS, and Receptor support. |
| `roles/eda` | Installs and upgrades Event-Driven Ansible with API, workers, UI, Redis, Postgres, and TLS. |
| `roles/gateway` | Installs and upgrades the Automation Platform Gateway and configures proxy/service resources. |
| `roles/haproxy` | Runs a simple HAProxy test frontend with generated or raw backend pools. |
| `roles/tls` | Creates or imports the shared Automation Platform root CA and trust material. |
| `roles/docker` | Installs/configures Docker for the demo hosts. |
| `roles/awx_settings` | Applies AWX settings through the AWX API. |
| `demo` | Inventories, host variables, group variables, and runnable playbooks. |
| `images` | Dockerfiles, build scripts, execution environment definitions, patches, and generated CRDs. |
| `charts` | Helm charts for Kubernetes/operator deployments. |

## Install the collection

Install the published collection from Ansible Galaxy:

```shell
ansible-galaxy collection install fitbeard.awx
```

Or pin a release, for example:

```shell
ansible-galaxy collection install fitbeard.awx:25.0.0
```

## Requirements

- Linux hosts with working DNS or `/etc/hosts` entries for the demo names.
- Ansible Core compatible with this repository, currently `<2.20.0`.
- Docker on target hosts, unless you let the demo `docker` role install it.
- OpenSSL for generating CA and service certificate material.
- For image builds: Docker Buildx, `git`, `curl`, `rpm2cpio`, `cpio`, and
  `ansible-builder` for execution environment images.
- For Helm/operator work: `kubectl`, `helm`, and access to any private registry
  required by your chosen image source.

## Demo topologies

Before running a playbook, review `demo/group_vars`, `demo/host_vars`, and the
chosen inventory. The demo files include test-only secrets.

Full platform behind Gateway:

```shell
cd demo
ansible-playbook -i inventory-gateway playbook-gateway.yml --diff
```

AWX standalone:

```shell
cd demo
ansible-playbook -i inventory-awx-standalone playbook-awx-standalone.yml --diff
```

EDA standalone:

```shell
cd demo
ansible-playbook -i inventory-eda-standalone playbook-eda-standalone.yml --diff
```

The demo expects these public names to resolve to the HAProxy endpoint:

- `awx.demo.io`
- `eda.demo.io`
- `gateway.demo.io`

The bundled `haproxy` role is for demo and testing topologies only. Production
deployments should use a real load balancer, ingress controller, or platform
edge service with proper high availability, health checks, observability, and
certificate lifecycle management.

## Generate a root CA

The `tls` role can create or import the shared Automation Platform CA. For real
deployments, generate your own root CA and place the values in inventory
variables such as `ap_ca_crt`, `ap_ca_key`, and `ap_ca_key_passphrase`.

```shell
export AP_CA_PASSPHRASE="your_passphrase"

openssl genrsa -aes256 -passout env:AP_CA_PASSPHRASE -out ap_ca_key 4096

openssl req -x509 -new \
  -key ap_ca_key \
  -passin env:AP_CA_PASSPHRASE \
  -subj "/CN=Automation Platform Demo Root CA" \
  -sha256 \
  -days 3650 \
  -out ap_ca_crt \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign"
```

AWX Receptor mesh material is separate from the platform root CA and must be
generated/configured independently.

## Generate AWX service mesh certificates

AWX service mesh traffic uses Receptor certificates, not the shared platform
root CA. Generate a mesh CA, a receptor work-signing key pair, and one
certificate/key pair for every AWX control, hybrid, hop, and execution node.

```shell
mkdir -p secrets
cd secrets

openssl genrsa -out awx_mesh_ca_key 4096
openssl req -x509 -new -nodes \
  -key awx_mesh_ca_key \
  -subj "/CN=AWX Demo Receptor Root CA" \
  -sha256 \
  -days 3650 \
  -out awx_mesh_ca_crt

openssl genrsa -out awx_receptor_signing_private_key 4096
openssl rsa \
  -in awx_receptor_signing_private_key \
  -out awx_receptor_signing_public_key \
  -outform PEM \
  -pubout
```

Generate one receptor certificate per mesh node. The `-n` value must match the
node name used by Receptor and Ansible inventory. Add `-na` or `-ni` when a node
also needs an extra DNS name or IP address in the certificate.

```shell
../scripts/receptor_keypair.sh -n awx-1.demo.io
../scripts/receptor_keypair.sh -n awx-2.demo.io
../scripts/receptor_keypair.sh -n awx-receptor-1.demo.io
../scripts/receptor_keypair.sh -n awx-receptor-hop-1.demo.io
```

Configure the shared mesh material in group variables, for example in
`demo/group_vars/all/awx.yml`:

```yaml
awx_mesh_ca_crt: "{{ lookup('ansible.builtin.file', playbook_dir ~ '/../secrets/awx_mesh_ca_crt') }}"
awx_mesh_ca_key: "{{ lookup('ansible.builtin.file', playbook_dir ~ '/../secrets/awx_mesh_ca_key') }}"

awx_receptor_signing_public_key: "{{ lookup('ansible.builtin.file', playbook_dir ~ '/../secrets/awx_receptor_signing_public_key') }}"
awx_receptor_signing_private_key: "{{ lookup('ansible.builtin.file', playbook_dir ~ '/../secrets/awx_receptor_signing_private_key') }}"
```

Configure each node's certificate and key in host variables, for example in
`demo/host_vars/awx-receptor-1.demo.io.yml`:

```yaml
awx_node_role_type: execution
awx_receptor_crt: "{{ lookup('ansible.builtin.file', playbook_dir ~ '/../secrets/' ~ inventory_hostname ~ '.crt') }}"
awx_receptor_key: "{{ lookup('ansible.builtin.file', playbook_dir ~ '/../secrets/' ~ inventory_hostname ~ '.key') }}"
```

Use `awx_node_role_type` to define the Receptor node type. Valid values are
`control`, `hybrid`, `hop`, and `execution`. Use `awx_peers` when a node needs
explicit outbound mesh peers:

```yaml
awx_node_role_type: hop
awx_peers:
  - address: awx-receptor-behind-hop-1.demo.io
```

Nodes default to peering from control nodes. Set
`awx_peers_from_control_nodes: false` on isolated execution nodes when you want
only explicit peer relationships.

## Images

The `images` directory contains reproducible rebuild scripts and execution
environment definitions. Most image builds support both `linux/amd64` and
`linux/arm64`.

| Image | Default tag | Source path |
| --- | --- | --- |
| `quay.io/fitbeard/automation-platform/awx` | `25.0.0` | `images/awx` |
| `quay.io/fitbeard/automation-platform/awx-ee` | `25.0.0` | `images/awx-ee` |
| `quay.io/fitbeard/automation-platform/gateway` | `2.6.20260422` | `images/gateway` |
| `quay.io/fitbeard/automation-platform/eda-server` | `1.2.8` | `images/eda` |
| `quay.io/fitbeard/automation-platform/eda-ui` | `2.6.8` | `images/eda` |
| `quay.io/fitbeard/automation-platform/eda-de` | `25.0.0` | `images/eda-de` |
| `quay.io/fitbeard/automation-platform/mcp-server` | upstream commit tag | `images/mcp-server` |
| `quay.io/fitbeard/automation-platform/awx-operator` | `2.6-709` | `images/awx-operator` |
| `quay.io/fitbeard/automation-platform/eda-server-operator` | `2.6-709` | `images/eda-server-operator` |
| `quay.io/fitbeard/automation-platform/awx-resource-operator` | `2.6-709` | `images/awx-resource-operator` |
| `quay.io/fitbeard/automation-platform/awx-resource-runner` | `2.6-709` | `images/awx-resource-operator` |
| `quay.io/fitbeard/automation-platform/ansible-ai-connect-operator` | `2.6-709` | `images/ansible-ai-connect-operator` |

Example builds:

```shell
cd images/awx
VERSION=25.0.0 ./build.sh --push

cd ../gateway
VERSION=2.6.20260422 ./build.sh --push
```

Execution environment images use `ansible-builder`:

```shell
cd images/awx-ee
ansible-builder create -v3 --file execution-environment.yml --context . --output-filename=Dockerfile
docker buildx build --platform linux/amd64,linux/arm64 --push \
  -t quay.io/fitbeard/automation-platform/awx-ee:25.0.0 .
```

`images/ap-gateway-operator` is special: the Gateway operator source is
extracted from the source-bundle OCI image. That path requires access
to the vendor's registry, and the chart intentionally defaults to
`quay.io/your-namespace/ap-gateway-operator` until you build and publish your
own copy.

## Helm charts

Helm charts live under `charts/`:

- `charts/awx-operator`
- `charts/eda-server-operator`
- `charts/ap-gateway-operator`
- `charts/awx-resource-operator`
- `charts/mcp-operator`

CRDs are intentionally not installed by the charts. Apply the CRDs from the
matching `images/*/crds` directory first, then install the charts.

```shell
kubectl create namespace ansible

kubectl apply -f images/awx-operator/crds/
kubectl apply -f images/eda-server-operator/crds/
kubectl apply -f images/awx-resource-operator/crds/
kubectl apply -f images/ansible-ai-connect-operator/crds/

helm upgrade --install awx-operator charts/awx-operator \
  --namespace ansible

helm upgrade --install eda-server-operator charts/eda-server-operator \
  --namespace ansible

helm upgrade --install awx-resource-operator charts/awx-resource-operator \
  --namespace ansible

helm upgrade --install mcp-operator charts/mcp-operator \
  --namespace ansible
```

Gateway operator CRDs are generated by the Gateway operator build process when
that source bundle is extracted. See `images/ap-gateway-operator/README.md` and
the sample CRs under `images/ap-gateway-operator/deploy/`.

After building and publishing the Gateway operator image, install its chart with
your image repository:

```shell
kubectl apply -f images/ap-gateway-operator/crds/

helm upgrade --install ap-gateway-operator charts/ap-gateway-operator \
  --namespace ansible \
  --set image.repository=quay.io/your-namespace/ap-gateway-operator
```

## Upgrades

Most roles use a task switch with `setup` as the default. Set the relevant
`*_tasks` variable to `upgrade` for upgrade runs:

```shell
cd demo
ansible-playbook -i inventory-gateway playbook-gateway.yml --diff \
  -e gateway_tasks=upgrade \
  -e awx_tasks=upgrade \
  -e eda_tasks=upgrade
```

For standalone deployments, set only the matching variable:

```shell
ansible-playbook -i inventory-awx-standalone playbook-awx-standalone.yml --diff \
  -e awx_tasks=upgrade

ansible-playbook -i inventory-eda-standalone playbook-eda-standalone.yml --diff \
  -e eda_tasks=upgrade
```

## Removing a component cleanly

This example is for Kubernetes deployment but comamnd used to remove services
is the same for both types of installation.
Example: removing EDA after a full reconcile.

```bash
# 1. Disable EDA on the AAP CR
kubectl edit aap <ap-name> -n ansible
#   eda:
#     disabled: true

# 2. Delete the EDA sub-CR — cascade GC cleans pods/services/secrets owned
#    by the eda-server-operator
kubectl delete eda <eda-name> -n ansible

# 3. Drop EDA's database + user inside the shared postgres + its secret
kubectl exec -n ansible <ap-name>-postgres-15-0 -- \
  psql -U postgres -c "DROP DATABASE IF EXISTS eda;"
kubectl exec -n ansible <ap-name>-postgres-15-0 -- \
  psql -U postgres -c "DROP USER IF EXISTS eda;"
kubectl delete secret <ap-name>-eda-postgres-configuration -n ansible

# 4. Drop the orphaned gateway ServiceCluster (cascades to ServiceNodes,
#    ServiceKeys, Routes, AdditionalRoutes, ServiceAPIRoutes)
GW_POD=$(kubectl get pod -n ansible -l app.kubernetes.io/component=aap-gateway \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ansible "$GW_POD" -c api -- aap-gateway-manage shell --no-imports \
  -c "from aap_gateway_api.models import ServiceCluster; \
      ServiceCluster.objects.filter(name='eda').delete()"
```

After step 4 the next reconcile runs cleanly — `migrate_service_data`
no longer trips on the orphan, no 503 from envoy.

## Contributing

Install the local development dependencies and hooks:

```shell
poetry install
poetry run pre-commit install --hook-type commit-msg
```

Run linting before opening a pull request:

```shell
poetry run ansible-lint
poetry run pre-commit run --all-files
```
