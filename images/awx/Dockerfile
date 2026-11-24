### Based on tools/ansible/roles/dockerfile/templates/Dockerfile.j2
### with build_dev=false, kube_dev=false.
###

FROM docker.io/rockylinux/rockylinux:9 AS builder

ENV LANG="en_US.UTF-8"
ENV LANGUAGE="en_US:en"
ENV LC_ALL="en_US.UTF-8"
ENV AWX_LOGGING_MODE="stdout"

USER root

RUN rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9

# Install build dependencies
RUN dnf -y update && dnf install -y 'dnf-command(config-manager)' && \
    dnf config-manager --set-enabled crb && \
    dnf -y install \
    openssh-clients \
    iputils \
    gcc \
    gcc-c++ \
    git-core \
    gettext \
    glibc-langpack-en \
    libffi-devel \
    libtool-ltdl-devel \
    make \
    nodejs \
    nss \
    openldap-devel \
    patch \
    postgresql \
    postgresql-devel \
    python3.12 \
    "python3.12-devel" \
    "python3.12-pip" \
    "python3.12-setuptools" \
    "python3.12-packaging" \
    "python3.12-psycopg2" \
    swig \
    unzip \
    xmlsec1-devel \
    xmlsec1-openssl-devel

# System pip is only used to install the `build` frontend below; the awx venv
# gets its own pip via ensurepip. No CVE version floor here (reset 2026-09) —
# re-audit the image and re-add a pin only if a finding requires it.
RUN pip3.12 install -vv build

# Install & build requirements
ADD Makefile /tmp/Makefile
RUN mkdir /tmp/requirements
ADD requirements/requirements.txt \
    requirements/requirements_tower_uninstall.txt \
    requirements/requirements_git.txt \
    requirements/requirements_git.credentials.txt \
    /tmp/requirements/

RUN git config --global credential.helper "store --file=/tmp/requirements/requirements_git.credentials.txt"

# DAB needs its version set for setuptools_scm during install
ARG DAB_PRETEND_VERSION
RUN SETUPTOOLS_SCM_PRETEND_VERSION_FOR_DJANGO_ANSIBLE_BASE=${DAB_PRETEND_VERSION} \
    cd /tmp && make requirements_awx

ARG VERSION
ARG SETUPTOOLS_SCM_PRETEND_VERSION
# Use the distro provided npm to bootstrap Node 20 LTS (required for aap-ui / Vite build)
RUN npm install -g n && n 20

# Copy source into builder, build sdist, install it into awx venv
COPY . /tmp/src/
WORKDIR /tmp/src/

# Pin setuptools<81 in pyproject.toml so isolated build envs get a version where
# pkg_resources still works (removed in setuptools>=81, see deprecation warning).
RUN sed -i 's/"setuptools>=45"/"setuptools>=45,<81"/' pyproject.toml

# NOTE: AAP 2.6 shipped a vendored-pip/distlib patch wired via `make patch_pip`;
# that Makefile target was REMOVED in the 2.7 controller source (4.8.14), so the
# step is dropped. The 2.7 tree pins pip/setuptools directly in the build
# (Containerfile: pip==25.3, setuptools==80.9.0) with no separate pip patch.

# Build the UI from AAP UI source (aap-ui, Apache-2.0).
# The source is copied into the build context by build.sh (section 6).
# We build only frontend/awx (standalone AWX UI with Vite), then place the
# output where AWX 2.7 expects it: awx/ui/build/awx/ (see the RUN below).
COPY aap-ui/ /tmp/aap-ui/
# Inject VERSION and PRODUCT into Vite build environment so the About modal
# shows the version string instead of undefined.  vite.config.ts defines
# `process.env` as a limited object — we add our vars to it.
RUN sed -i 's/  AWX_WEBSOCKET_PREFIX,/  AWX_WEBSOCKET_PREFIX,\n  VERSION: process.env.VERSION || "",\n  PRODUCT: "AWX",/' /tmp/aap-ui/frontend/awx/vite.config.ts
# `npm install` (not `npm ci`): the vendor's Cachi2-wired lockfile was stripped
# in build.sh so deps resolve from the public npm registry at package.json
# versions (the .npmrc keeps ignore-scripts + min-release-age guards).
# Place the built UI at awx/ui/build/awx — the native 2.7 UI location. AAP 2.5+
# made the controller headless and moved the UI dir from ui_next/build → ui/build:
# 4.8.14's settings put `awx/ui/build/awx` in TEMPLATES.DIRS (where IndexView
# resolves index_awx.html) and `awx/ui/build` in STATICFILES_DIRS, and MANIFEST.in
# already ships `recursive-include awx/ui/build *`. So building here needs NO
# settings/MANIFEST patch — Django finds the template and collectstatic the assets.
RUN cd /tmp/aap-ui && VERSION="${VERSION}" npm install && \
    cd frontend/awx && VERSION="${VERSION}" npx vite build --base /static/awx/ && \
    mkdir -p /tmp/src/awx/ui/build/awx && \
    cp -r dist/* /tmp/src/awx/ui/build/awx/ && \
    mv /tmp/src/awx/ui/build/awx/index.html /tmp/src/awx/ui/build/awx/index_awx.html && \
    cp /tmp/aap-ui/frontend/assets/awx-logo.svg /tmp/src/awx/ui/build/awx/awx-logo.svg && \
    (cp /tmp/aap-ui/frontend/assets/awx-icon.svg /tmp/src/awx/ui/build/awx/awx-icon.svg 2>/dev/null || true) && \
    rm -rf /tmp/aap-ui

# Debrand the built UI bundle: collapse "<Vendor> <Brand> Automation Platform" ->
# "Automation Platform" across the compiled JS/CSS assets AND the i18next locale
# files (locales/<lang>/translation.json — i18next renders values straight from
# these, and uses the English sentence as the lookup key, so both the .js keys and
# the .json keys/values must collapse identically to stay consistent). Operating on
# the built output (not the TSX source) catches product-name strings from our own
# components (e.g. the HashiCorp Vault OIDC config panel) AND any pulled in from
# bundled dependencies, in a single structural pass. The mark is never written here.
RUN find /tmp/src/awx/ui/build/awx -type f \( -name '*.js' -o -name '*.css' -o -name '*.json' \) \
      -exec sed -i -E 's|([A-Z][a-z]+ )+Automation Platform|Automation Platform|g' {} +

# Build sdist with HEADLESS=yes to skip Makefile UI targets.
RUN HEADLESS=yes make sdist && /var/lib/awx/venv/awx/bin/pip install dist/awx.tar.gz

# Debrand the runtime product name across the installed awx_plugins package:
#   - interfaces/_temporary_private_licensing_api.py: detect_server_product_name()
#     returns the vendor's branded name when /var/lib/awx/.tower_version is present
#     (drives X-API-Product-Name, the upgrade page, ...).
#   - credentials/plugins.py + inventory/plugins.py: credential-type / inventory
#     field labels + help_text that surface in the UI create-credential wizards.
# Structural collapse "<Vendor> <Brand> Automation Platform" -> "Automation Platform"
# (the mark is never written here). detect_server_product_name stays != 'AWX', so the
# full managed credential-type and inventory-source sets still load. Stale .pyc are
# recompiled at runtime (mtime bump).
RUN d="$(find /var/lib/awx/venv -type d -name awx_plugins | head -1)" && \
    test -n "$d" && \
    find "$d" -name '*.py' -exec sed -i -E 's|([A-Z][a-z]+ )+Automation Platform|Automation Platform|g' {} + && \
    grep -q "'Automation Platform'" "$d/interfaces/_temporary_private_licensing_api.py"

# Collect static files.
# AWX_MODE=defaults bypasses the production settings assertion (no /etc/tower/ needed).
# AWX_SKIP_CREDENTIAL_TYPES_DISCOVER=yes avoids DB-dependent credential type discovery.
RUN AWX_MODE=defaults SKIP_SECRET_KEY_CHECK=yes SKIP_PG_VERSION_CHECK=yes AWX_SKIP_CREDENTIAL_TYPES_DISCOVER=yes /var/lib/awx/venv/awx/bin/awx-manage collectstatic --noinput --clear

RUN rm /tmp/requirements/requirements_git.credentials.txt

# Final container(s)
FROM docker.io/rockylinux/rockylinux:9

ENV LANG="en_US.UTF-8"
ENV LANGUAGE="en_US:en"
ENV LC_ALL="en_US.UTF-8"
ENV AWX_LOGGING_MODE="stdout"

USER root

RUN rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9

ADD https://copr.fedorainfracloud.org/coprs/ansible/Rsyslog/repo/epel-9/ansible-Rsyslog-epel-9.repo /etc/yum.repos.d/ansible-Rsyslog-epel-9.repo

# Install runtime requirements
RUN dnf -y update && dnf install -y 'dnf-command(config-manager)' && \
    dnf config-manager --set-enabled crb && \
    dnf -y install acl \
    findutils \
    git-core \
    git-lfs \
    glibc-langpack-en \
    hostname \
    krb5-workstation \
    nginx \
    "openldap >= 2.6.2-3" \
    podman-remote \
    postgresql \
    python3.12 \
    "python3.12-devel" \
    "python3.12-pip*" \
    "python3.12-setuptools" \
    "python3.12-packaging" \
    "python3.12-psycopg2" \
    rsync \
    rsyslog \
    subversion \
    sudo \
    vim-minimal \
    which \
    unzip \
    xmlsec1-openssl && \
    dnf -y clean all

# Runtime tooling. No CVE version floors (reset 2026-09) — re-audit and re-add
# only what a finding requires. setuptools<81 is a FUNCTIONAL bound (pkg_resources
# was removed in setuptools>=81), not a CVE override, so it stays.
RUN pip3.12 install -vv virtualenv supervisor dumb-init build "setuptools<81"

RUN rm -rf /root/.cache && rm -rf /tmp/*

# Copy app from builder
COPY --from=builder /var/lib/awx /var/lib/awx

# AAP product marker. awx_plugins' runtime-name helper
# (detect_server_product_name in awx_plugins.interfaces._temporary_private_licensing_api)
# treats the install as community AWX UNLESS /var/lib/awx/.tower_version exists.
# In the community-AWX path, load_credentials() (awx/main/models/credential.py)
# registers ONLY the 8 base managed credential types and skips BOTH the
# `awx_plugins.managed_credentials.supported` set (cloud providers: aws, azure_rm,
# gce, vmware, openstack, satellite6, ...) AND every `awx_plugins.credentials`
# external secret-backend plugin (HashiCorp, CyberArk, Azure KV, Thycotic, AWS SM,
# GitHub App, ...). The vendor's packaging drops this marker file; our
# source rebuild must create it to get the full set (8 -> 34 types). Its content
# MUST equal awx.__version__ or the asgi.py/wsgi.py production version check
# hard-fails — derive it from the installed package so it can never drift.
RUN /var/lib/awx/venv/awx/bin/python -c "import awx; print(awx.__version__)" > /var/lib/awx/.tower_version

RUN ln -s /var/lib/awx/venv/awx/bin/awx-manage /usr/bin/awx-manage

# nginx config — provides working defaults for uwsgi/daphne/websocket routing
ADD _build/nginx.conf /etc/nginx/nginx.conf

ADD tools/ansible/roles/dockerfile/files/rsyslog.conf /var/lib/awx/rsyslog/rsyslog.conf
ADD tools/ansible/roles/dockerfile/files/wait-for-migrations /usr/local/bin/wait-for-migrations
ADD tools/ansible/roles/dockerfile/files/stop-supervisor /usr/local/bin/stop-supervisor

ADD tools/ansible/roles/dockerfile/files/uwsgi.ini /etc/tower/uwsgi.ini

ADD tools/ansible/roles/dockerfile/files/launch_awx_web.sh /usr/bin/launch_awx_web.sh
ADD tools/ansible/roles/dockerfile/files/launch_awx_task.sh /usr/bin/launch_awx_task.sh
ADD tools/ansible/roles/dockerfile/files/launch_awx_rsyslog.sh /usr/bin/launch_awx_rsyslog.sh
ADD tools/scripts/rsyslog-4xx-recovery /usr/bin/rsyslog-4xx-recovery
ADD _build/supervisor_web.conf /etc/supervisord_web.conf
ADD _build/supervisor_task.conf /etc/supervisord_task.conf
ADD _build/supervisor_rsyslog.conf /etc/supervisord_rsyslog.conf
ADD tools/scripts/awx-python /usr/bin/awx-python

# Ensure launch scripts and utilities are executable
RUN chmod +rx /usr/bin/launch_awx_web.sh /usr/bin/launch_awx_task.sh /usr/bin/launch_awx_rsyslog.sh /usr/local/bin/wait-for-migrations /usr/local/bin/stop-supervisor

# Pre-create things we need to access
RUN for dir in \
      /var/lib/awx \
      /var/lib/awx/rsyslog \
      /var/lib/awx/rsyslog/conf.d \
      /var/lib/awx/.local/share/containers/storage \
      /var/run/awx-rsyslog \
      /var/log/nginx \
      /var/lib/pgsql \
      /var/run/supervisor \
      /var/run/awx-receptor \
      /var/lib/nginx ; \
    do mkdir -m 0775 -p $dir ; chmod g+rwx $dir ; chgrp root $dir ; done && \
    for file in \
      /etc/subuid \
      /etc/subgid \
      /etc/group \
      /etc/passwd \
      /var/lib/awx/rsyslog/rsyslog.conf ; \
    do touch $file ; chmod g+rw $file ; chgrp root $file ; done

RUN ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log

ENV HOME="/var/lib/awx"

USER 1000
EXPOSE 8052

ENTRYPOINT ["dumb-init", "--"]
VOLUME /var/lib/nginx
VOLUME /var/lib/awx/.local/share/containers
