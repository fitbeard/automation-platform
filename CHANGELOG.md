# Changelog

## [24.6.330](https://github.com/fitbeard/awx-without-k8s/compare/v24.6.281...v24.6.330) (2026-03-07)

### Features

* Code cleanup and dependency update
* New build scripts for AWX and EE
* AWX and EE images for `linux/amd64` and `linux/arm64` platforms

#### AWX 24.6.1 → AAP 2.6.5 (commit 03140796f620)

**330 commits** between tag `24.6.1` and commit `03140796f620966cdc4ff5052978c80a51c94ca7`.

Source: [GitHub comparison](https://github.com/ansible/awx/compare/24.6.1...03140796f620966cdc4ff5052978c80a51c94ca7)

### New AWX Features

#### ESXi Inventory Plugin

- ESXi inventory plugin support (`d35d7f62ec46`)
- Logic to replace credential name when using ESXi (`60114ab92943`)

#### Azure Key Vault Managed Identity

- Azure Key Vault plugin updated to use Managed Identity (`ba7ee2329828`)

#### Credential sharing

- Credential sharing across organizations (`ceb2eeccd1`): Credentials can now be shared between organizations.

#### Redis

- Connection resilience (`a49da9a19f`): New `REDIS_RETRY_COUNT`, `REDIS_BACKOFF_CAP`, `REDIS_BACKOFF_BASE`
settings for automatic retry on broken pipe.

## Security Fixes

- **CVE-2025-6176** (`ec02f8b991`)
- **CVE-2025-66471**: urllib3 upgraded to 2.6.3 (`919022d624`)
- **Django 4.2.27** security update (`e5db05ff3f`)

## Kubernetes Operator

New images (both AWX and EE) can also be used with [awx-operator](https://docs.ansible.com/projects/awx-operator/en/latest/)
but an external nginx.conf config compatible with this version should be used. See [`nginx.conf`](./roles/awx/templates/awx-nginx.conf.j2)
for the reference.

## [24.6.281](https://github.com/fitbeard/awx-without-k8s/compare/v24.6.2...v24.6.281) (2026-03-03)

### Features

* Code cleanup and dependency update
* New build scripts for AWX and EE
* AWX and EE images for `linux/amd64` and `linux/arm64` platforms

### *** AWX resurrection ***

#### AWX 24.6.1 → AAP 2.6.1 (commit 05626248ce26)

**281 commits** between tag `24.6.1` and commit `05626248ce26fda2d64f311e494cfd146e7e4f2e`.

Source: [GitHub comparison](https://github.com/ansible/awx/compare/24.6.1...05626248ce26fda2d64f311e494cfd146e7e4f2e)

### New AWX Features

### GitHub App Authentication (Credential Plugin)
- New credential plugin for GitHub App authentication (`9d9c125e470e`)
- Allows `x-access-token@<github-access-token>` for git auth (`9d9c125e470e`)
- Adds PyGithub and PyNaCl dependencies (`9d9c125e470e`)

## Security Fixes

- **CVE-2024-33663**: python-jose vulnerability (`467024bc54a8`)
- **CVE-2024-21520**: stringview vulnerability (`bcd18e161cdb`)
- **CVE-2024-37891**: urllib3 vulnerability (`eb4f3c2864d3`)
- **CVE-2024-52304**: aiohttp vulnerability (`2c3b4ff5d786`)
- **CVE-2024-53908**: Django vulnerability (`b361aef0fbc5`)
- **CVE-2024-56201**: Jinja2 vulnerability (`a209751f22eb`)
- **CVE-2024-56374**: Django vulnerability (`2e8114394b91`)
- **CVE-2024-11407**: grpcio vulnerability (`df79fa4ae1a6`)
- **CVE-2025-47273**: setuptools vulnerability (`8fe4223eaccd`)
- **CVE-2025-48432**: Django vulnerability (`e3a9d9fbe8e8`)
- **CVE-2025-57833**: Django 4.2.24 update (`9e1025ce84f8`)
- Jinja2 additional CVE fix (`b5bc85e639c2`)
- Django multiple CVE updates (`8b293e704687`, `d1c85dae4ded`, `a238c5dd09da`, `6a10e0ea5c2a`)
- Prevent `automountServiceAccountToken` on K8s pods (`15e28371ebb3`)
- Prevent system auditor from downloading install bundle (`1e6a7c074967`)
- Django password validators now applied correctly (`e060e44b0503`)

## Kubernetes Operator
New images (both AWX and EE) can also be used with [awx-operator](https://docs.ansible.com/projects/awx-operator/en/latest/user-guide/advanced-configuration/extra-settings.html#add-extra-settings-with-extra_settings):

```yaml
spec:
  image: quay.io/tadas/awx
  image_version: 24.6.1.post281
  control_plane_ee_image: quay.io/tadas/awx-ee:24.6.1.post281
  extra_settings:
    - setting: UI_NEXT
      value: "'False'"
```

## [24.6.2](https://github.com/fitbeard/awx-without-k8s/compare/v24.6.1...v24.6.2) (2024-12-29)

### Features

* Code cleanup and dependency update

## [24.6.1](https://github.com/fitbeard/awx-without-k8s/compare/v24.2.0...v24.6.1) (2024-09-03)

### Features

* Updated to support AWX version `24.6.1`

### Improvements

* Added script for mesh key pair generation

## [24.2.0](https://github.com/fitbeard/awx-without-k8s/compare/v23.7.0...v24.2.0) (2024-04-18)

### Features

* Updated to support AWX version `24.2.0`
* Due to changes upstream dropped manual peering support which relied on AWX code patching.
  Please consider to change your deployment topology.
  This will only impact interconnection between AWX control plane nodes which from now is always needed.

### *** Breaking changes ***

* All instances including management nodes must be deprovisioned before upgrade:

  `awx-manage deprovision_instance --hostname=XXXX`

* Postgres backend should be migrated/updated to version 15 before upgrading to this release

  As a safeguard special flag is introduced:

  `awx_pg_is_on_supported_version: false`

* Short upgrade instruction for setup with dockerized Postgres database [`UPGRADE`](./UPGRADE.md)

## [23.7.0](https://github.com/fitbeard/awx-without-k8s/compare/v23.5.1...v23.7.0) (2024-02-13)

### Features

* Updated to support AWX version `23.7.0`

### Improvements

* Bootstrap dependencies are now tracked using `poetry`

## [23.5.1](https://github.com/fitbeard/awx-without-k8s/compare/v23.3.0...v23.5.1) (2023-12-14)

### Features

* Updated to support AWX version `23.5.1`

## [23.3.0](https://github.com/fitbeard/awx-without-k8s/compare/v22.7.0...v23.3.0) (2023-10-17)

### Features

* Updated to support AWX version `23.3.0`
* Added role `awx_settings` for AWX settings configuration. Initial version.
* Added meta role `defaults` for variables used by more then one role

### Improvements

* Fixed code indempotency in some tasks by switching to `awx.awx` collection

## [22.7.0](https://github.com/fitbeard/awx-without-k8s/compare/v22.5.0...v22.7.0) (2023-08-17)

### Features

* Updated to support AWX version `22.7.0`

### Improvements

* Make more Nginx params configurable
* Make more Uwsgi params configurable

## [22.5.0](https://github.com/fitbeard/awx-without-k8s/compare/v22.4.0...v22.5.0) (2023-07-25)

### Features

* Updated to support AWX version `22.5.0`

## [22.4.0](https://github.com/fitbeard/awx-without-k8s/compare/v22.2.0...v22.4.0) (2023-07-07)

### Features

* Updated to support AWX version `22.4.0`
* Renamed variables:

  `awx_receptor_ca_crt` to `awx_mesh_ca_crt`

  `awx_receptor_ca_key` to `awx_mesh_ca_key`

### Improvements

* Make workers uuids static
* Make Postgres keepalives options configurable

## [22.2.0](https://github.com/fitbeard/awx-without-k8s/compare/v22.0.0...v22.2.0) (2023-05-11)

### Features

* Updated to support AWX version `22.2.0`

## 22.0.0 (05 April, 2023)

FEATURES

* Updated to support AWX version `22.0.0`

## 21.14.0 (05 April, 2023)

FEATURES

* Updated to support AWX version `21.14.0`

IMPROVEMENTS

* Fix SELinux permission denied issue inside custom `awx-ee` container

## 21.13.0 (10 March, 2023)

FEATURES

* Updated to support AWX version `21.13.0`

## 21.12.0 (14 February, 2023)

FEATURES

* Updated to support AWX version `21.12.0`

## 21.11.0 (02 February, 2023)

FEATURES

* Updated to support AWX version `21.11.0`

IMPROVEMENTS

* Custom EE image is now available for both `linux/amd64` and `linux/arm64` architectures

* Starting with this release the code is only compatible with Ansible version 4.0.0 and above

* This code is now avaibale in an Ansible collection form.

  It can be installed with the command:

  `ansible-galaxy collection install fitbeard.awx`

  or

  `ansible-galaxy collection install fitbeard.awx:21.11.0`

## 21.10.2 (21 December, 2022)

FEATURES

* Updated to support AWX version `21.10.2`

## 21.9.0 (23 November, 2022)

FEATURES

* Updated to support AWX version `21.9.0`
* Added manual peering scenario (Automation Platform style)
* Added hop node support

IMPROVEMENTS

* Now new execution and hop nodes are added automatically during configuration

## 21.8.0 (04 November, 2022)

FEATURES

* Updated to support AWX version `21.8.0`

## 21.7.0 (21 October, 2022)

FEATURES

* Updated to support AWX version `21.7.0`

IMPROVEMENTS

* Total code refactoring

## 17.0 (08 February, 2021)

FEATURES

* Updated to support AWX version `17.x`

## 16.0 (18 December, 2020)

FEATURES

* Updated to support AWX version `16.x`

## 14.0 (27 December, 2020)

FEATURES

* Updated to support AWX version `14.x`

## 11.0 (27 April, 2020)

FEATURES

* Updated to support AWX version `11.x`
