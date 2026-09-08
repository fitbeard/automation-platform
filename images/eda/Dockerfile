###
### Build EDA Server from source.
### Based on tools/docker/Dockerfile from the eda-server repo.
###

FROM docker.io/rockylinux/rockylinux:9 AS builder

ARG PYTHON_BIN="python3.12"
ARG USER_ID=1001

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV PYTHONDONTWRITEBYTECODE=1
ENV PIP_NO_CACHE_DIR=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV POETRY_NO_INTERACTION=1
ENV VIRTUAL_ENV=/app/venv
ENV SOURCES_DIR=/app/src
ENV HOME="/app"

USER root

# Install build dependencies
RUN dnf -y install dnf-plugins-core && \
    dnf -y config-manager --set-enabled crb && \
    dnf -y install \
    gcc \
    gcc-c++ \
    git-core \
    java-17-openjdk-headless \
    libffi-devel \
    libpq-devel \
    openssh-clients \
    ${PYTHON_BIN} \
    ${PYTHON_BIN}-devel \
    ${PYTHON_BIN}-pip \
    && dnf clean all

# Create eda user
RUN useradd --uid "$USER_ID" --gid 0 --home-dir /app --create-home eda && \
    mkdir -p /app/.local /var/lib/eda/ && \
    chown -R "${USER_ID}:0" /app/.local /var/lib/eda && \
    chmod 0775 /app /var/lib/eda

USER "$USER_ID"
ENV PATH="/app/.local/bin:$PATH"

# Install Poetry as user (outside venv), create venv separately
# This matches the Dockerfile pattern and avoids Poetry/pip conflicts.
RUN ${PYTHON_BIN} -m pip install --user "poetry>=2,<3" && \
    ${PYTHON_BIN} -m venv "$VIRTUAL_ENV" && \
    poetry config virtualenvs.create false && \
    poetry config system-git-client true

WORKDIR $SOURCES_DIR
ENV PATH="${VIRTUAL_ENV}/bin:$PATH"

# Copy dependency files first (for layer caching)
COPY poetry.toml pyproject.toml poetry.lock $SOURCES_DIR/

# Fix ownership (COPY as root)
USER 0
RUN chown -R ${USER_ID}:0 $SOURCES_DIR
USER "$USER_ID"

# Install dependencies into venv
# Strategy: strip DAB (private SSH URL) from pyproject.toml, poetry install the rest,
# then pip install DAB from public HTTPS with pinned commit.
ARG DAB_COMMIT
ARG DAB_EXTRAS="channel-auth,rbac,redis-client,resource-registry,jwt-consumer,rest-filters,feature-flags"
RUN sed -i '/^django-ansible-base/,/^\]/d' pyproject.toml && \
    poetry lock --no-interaction && \
    poetry install -E all --without test,lint,dev --no-root --no-cache && \
    pip install --no-cache-dir \
        "django-ansible-base[${DAB_EXTRAS}] @ git+https://github.com/ansible/django-ansible-base@${DAB_COMMIT}"

# Install runtime tools
RUN pip install --no-cache-dir gunicorn daphne

# CVE bumps — residual critical/high from `docker scout` on the clean 1.2.12
# build (reset 2026-09). 1.2.12's poetry.lock still resolves vulnerable
# transitives, so these force-upgrade past it. Each clears its finding with a
# stable, wheel-installable fix.
#   django   5.2.9  -> 5.2.13  (5H: CVE-2026-1287/-1207 SQLi, -3902 auth-bypass, -33034 DoS, +1)
#   sqlparse 0.5.3  -> 0.6.0   (3H: CVE-2026-71491/-54284 ReDoS-DoS, -59893)
#   azure-core 1.34.0 -> 1.38.0 (1H: CVE-2026-21226 untrusted deserialization)
#   click    8.1.3  -> 8.3.3   (1H)
#
# NOT bumped (documented):
#   cryptography 46.0.7 (3H: GHSA-537c/CVE-2026-69249/-69247) — pyOpenSSL 26.0.0
#     hard-caps cryptography>=46.0.0,<47; fixes need >=48.0.1. Deferred (needs a
#     pyopenssl stack bump). Same block as the AWX 4.7.16 refresh.
#   twisted 24.7.0 (1H: CVE-2026-42304) — only fix is 26.4.0rc2 (pre-release).
#   ecdsa 0.18.0 (1H: CVE-2024-23342 Minerva timing) — no upstream fix exists.
#   black/httpie (were 1C+2H) — dev/lint/test-group deps, now excluded from the
#     image via `poetry install --without test,lint,dev` above (not shipped).
RUN pip install --no-cache-dir --upgrade \
    "django>=5.2.13,<6.0" \
    "sqlparse>=0.6.0,<0.7" \
    "azure-core>=1.38.0,<2.0" \
    "click>=8.3.3,<9.0"

# Copy full source and install the EDA package itself
COPY . $SOURCES_DIR/
USER 0
RUN chown -R ${USER_ID}:0 $SOURCES_DIR
USER "$USER_ID"
RUN pip install --no-cache-dir --no-deps .

# Install ansible-core (needed by ansible-runner for running playbooks)
RUN pip install --no-cache-dir "ansible-core==2.18.*"

# Collect static files
RUN EDA_SECRET_KEY=placeholder EDA_DB_HOST=placeholder \
    aap-eda-manage collectstatic --noinput

# =============================================================================
# Runtime stage
# =============================================================================
FROM docker.io/rockylinux/rockylinux:9

ARG PYTHON_BIN="python3.12"
ARG USER_ID=1001

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en

USER root

RUN dnf -y update && dnf install -y \
    glibc-langpack-en \
    java-17-openjdk-headless \
    libpq \
    ${PYTHON_BIN} \
    git-core \
    && dnf clean all

# Copy venv and static files from builder
COPY --from=builder /app/venv /app/venv
COPY --from=builder /var/lib/eda/static /var/lib/eda/static

ENV PATH="/app/venv/bin:$PATH"
ENV VIRTUAL_ENV="/app/venv"

# Create eda user
RUN useradd --uid "$USER_ID" --gid 0 --home-dir /app --create-home eda && \
    mkdir -p /var/lib/eda/static /var/lib/eda/files && \
    chown -R eda:root /var/lib/eda && \
    mkdir -p /app/.ansible/tmp && \
    chown -R eda:root /app/.ansible && \
    mkdir /app/.ssh && \
    chown -R eda:root /app/.ssh

USER $USER_ID
WORKDIR /app

EXPOSE 8000

# Default CMD — compose overrides this per service role
CMD ["gunicorn", "-b", "0.0.0.0:8000", "-w", "4", "--no-control-socket", "aap_eda.wsgi", "--access-logfile", "-"]
