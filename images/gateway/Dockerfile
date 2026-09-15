ARG PYTHON=python3.12

# =============================================================================
# UI Builder stage: build Platform UI (Vite SPA) from SRPM source
# =============================================================================
FROM docker.io/rockylinux/rockylinux:9 AS ui-builder

# Use the distro-provided npm to bootstrap Node 20 LTS (required for Vite build)
RUN dnf install -y nodejs && npm install -g n && n 20

# Copy platform UI source (placed in build context by build.sh)
COPY aap-ui/ /tmp/aap-ui/
RUN cd /tmp/aap-ui && npm ci
RUN cd /tmp/aap-ui/platform && NODE_OPTIONS=--max-old-space-size=8192 npx vite build

# =============================================================================
# Python Builder stage: install Python deps into a venv
# =============================================================================
FROM docker.io/rockylinux/rockylinux:9 AS builder
ARG PYTHON=python3.12

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en

RUN dnf install -y epel-release && \
    dnf config-manager --set-enabled crb && \
    dnf install -y \
    git \
    gcc \
    ${PYTHON}-devel \
    ${PYTHON} \
    ${PYTHON}-pip \
    libpq \
    libpq-devel \
    libtool-ltdl-devel \
    openldap-devel \
    xmlsec1-devel && \
    dnf clean all

RUN mkdir -p /opt/aap_gateway && chgrp -R 0 /opt/aap_gateway && chmod -R g=u /opt/aap_gateway

RUN /usr/bin/${PYTHON} -m venv /opt/aap_gateway/venv
RUN echo "/opt/aap_gateway/aap_gateway" > /opt/aap_gateway/venv/lib/${PYTHON}/site-packages/project.pth

# Upper bound <81 keeps pkg_resources (removed in 81; gateway transitive deps
# still rely on it) — a FUNCTIONAL bound, not a CVE floor.
RUN /opt/aap_gateway/venv/bin/pip install --upgrade 'setuptools<81'

COPY requirements/requirements.txt /tmp/requirements.txt
COPY requirements/requirements_git.txt /tmp/requirements_git.txt
RUN /opt/aap_gateway/venv/bin/pip --no-cache-dir install -r /tmp/requirements.txt
RUN /opt/aap_gateway/venv/bin/pip --no-cache-dir install -r /tmp/requirements_git.txt
RUN /opt/aap_gateway/venv/bin/pip --no-cache-dir install colorama logutils

# CVE bumps — residual critical/high from `docker scout` on the clean
# 2.6.20260824 build (reset 2026-09; the SRPM already carries cryptography
# 48.0.0, certifi 2026.7.22, requests-current, so far fewer than before).
#   django   5.2.9  -> 5.2.13  (5H: CVE-2026-3902/-33034/-1287/-1207/-33033 + more)
#   sqlparse 0.5.3  -> 0.6.0   (3H: CVE-2026-71491/-54284 ReDoS-DoS, -59893)
#   cryptography 48.0.0 -> 50.0.0 (3H: GHSA-537c OOB, CVE-2026-69249 DoS, -69247
#     timing). Gateway's dep set does NOT cap cryptography <47 (unlike awx/eda's
#     pyopenssl 26.0.0), so the full fix line resolves.
#
# NOT bumped (documented):
#   lxml 5.3.0 -> 6.1.0 (major, SAML/XML risk), protobuf 5.29.5 -> 6.33.5
#   (major, gRPC risk). setuptools 53.0.0/68.2.2, wheel 0.45.1, jaraco-context
#   5.3.0 = RPM/bootstrap/build-tooling shadows (the aap_gateway venv ships
#   fixed setuptools<81 etc). social-auth-app-django CVE-2025-61783 stays
#   BLOCKED — DAB hard-pins ==5.4.1; a >= here silently resolves back to 5.4.1.
RUN /opt/aap_gateway/venv/bin/pip install --no-cache-dir --upgrade \
    "django>=5.2.13,<6.0" \
    "sqlparse>=0.6.0,<0.7" \
    "cryptography>=50.0.0,<51"

# Install the gateway package itself
ARG VERSION
ARG SETUPTOOLS_SCM_PRETEND_VERSION
COPY . /tmp/gateway-src
RUN cd /tmp/gateway-src && /opt/aap_gateway/venv/bin/pip --no-cache-dir install .

# =============================================================================
# Runtime stage
# =============================================================================
FROM docker.io/rockylinux/rockylinux:9
ARG PYTHON=python3.12

RUN dnf -y update --security --bugfix && \
    dnf install -y epel-release && \
    dnf module install -y nginx:1.26/common && \
    dnf install -y \
    glibc-langpack-en \
    less \
    libpq \
    ${PYTHON} \
    ${PYTHON}-pip \
    supervisor \
    xmlsec1-openssl && \
    dnf clean all

COPY --from=builder /opt/aap_gateway /opt/aap_gateway
COPY tools/scripts/launch-gateway /usr/bin/launch-gateway
COPY tools/scripts/aap-gateway-manage /usr/bin/aap-gateway-manage
COPY tools/configs/nginx.conf /etc/ansible-automation-platform/gateway/nginx.conf
COPY tools/configs/nginx-gateway.conf /etc/ansible-automation-platform/gateway/nginx-gateway.conf
COPY tools/configs/uwsgi.ini /etc/ansible-automation-platform/gateway/uwsgi.ini
COPY tools/configs/supervisord.conf /etc/supervisord.conf
COPY tools/scripts/envoy-path-rewrite.lua /etc/ansible-automation-platform/gateway/envoy-path-rewrite.lua

RUN for dir in \
      /etc/nginx \
      /opt/aap_gateway \
      /opt/aap_gateway/src \
      /opt/aap_gateway/static \
      /var/log/supervisor \
      /var/run/supervisor \
      /var/run/uwsgi \
      /var/run/nginx \
      /var/log/nginx \
      /var/log/ansible-automation-platform/gateway \
      /var/cache/ansible-automation-platform/gateway \
      /var/run/django_metrics ; \
    do mkdir -m 0775 -p "$dir" ; chmod g+rwx "$dir" ; chgrp root "$dir" ; done && \
    for file in \
      /etc/nginx/gateway.crt \
      /etc/nginx/gateway.key ; \
    do touch "$file" ; chmod g+rw "$file" ; chgrp root "$file" ; done && \
    ln -s /usr/bin/aap-gateway-manage /usr/bin/gateway-manage && \
    chmod +x /usr/bin/launch-gateway /usr/bin/aap-gateway-manage

RUN chown -R 1000 /opt/aap_gateway/static
RUN chown -R 1000 /var/cache/ansible-automation-platform/gateway

# Required for xds protobuf definitions compatibility with protobuf 3.21+
ENV PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

COPY aap_gateway_api /opt/aap_gateway/src/aap_gateway_api/

# VERSION file: read by aap_gateway_api.version at runtime
COPY VERSION /opt/aap_gateway/src/VERSION

ENV PATH=/opt/aap_gateway/venv/bin:$PATH
ENV PYTHONPATH=/opt/aap_gateway/src
ENV DJANGO_SETTINGS_MODULE=aap_gateway_api.settings

# Pull in the platform-ui built from SRPM source (Apache-2.0)
COPY --from=ui-builder /tmp/aap-ui/platform/dist /opt/aap_gateway/platform_ui

USER 1000
EXPOSE 8000
EXPOSE 50051

WORKDIR /opt
CMD ["/usr/bin/launch-gateway"]
