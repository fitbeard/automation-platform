###
### aap-mcp-server
###

FROM docker.io/rockylinux/rockylinux:9-minimal AS dumb_init_build
USER root
RUN microdnf install --setopt=install_weak_deps=0 --nodocs -y gcc \
    && microdnf clean all
COPY deps/dumb-init /deps/dumb-init
WORKDIR /deps/dumb-init
RUN gcc -std=gnu99 -O2 -g -o dumb-init dumb-init.c

FROM docker.io/rockylinux/rockylinux:9-minimal AS builder
USER root
RUN microdnf module enable -y nodejs:22 \
    && microdnf install --setopt=install_weak_deps=0 --nodocs -y nodejs npm \
    && microdnf clean all
WORKDIR /app
COPY src/package*.json src/tsconfig.json ./
# CVE overrides (now SDK v2) — extend upstream's own `overrides` block.
# These are patch-level bumps on express@5 transitive deps (express comes via the
# MCP SDK v2 server). Regenerating the lock with them applied is how upstream clears
# npm-audit findings:
#   proxy-addr  2.0.7 -> 2.0.8  (CVE-2026-90711, auth-bypass-by-spoofing)
#   body-parser 2.3.0 -> 2.4.0  (CVE-2026-111181)
# NOT overridden: zod major (the MCP SDK pins zod@3). Now that we ship SDK v2 the
# prior SDK-v1 advisory is moot — re-audit with `docker scout` after build and
# re-derive this override set from the SDK-v2 scan.
RUN node -e "const fs=require('fs');const p=JSON.parse(fs.readFileSync('package.json'));p.overrides={...(p.overrides||{}),'proxy-addr':'>=2.0.8','body-parser':'>=2.4.0'};fs.writeFileSync('package.json',JSON.stringify(p,null,2))"
# npm install (not ci) regenerates package-lock.json with the overrides applied
RUN npm install
COPY src/src/ ./src/
RUN npm run build
# Strip devDependencies so the node_modules we ship to the runtime stage is
# production-only — the runtime image then needs no npm at all (npm's own CLI
# deps pacote/sigstore/picomatch carried the only remaining npm highs).
RUN npm prune --omit=dev

FROM docker.io/rockylinux/rockylinux:9-minimal
USER root
# No `npm` in the runtime image — the app is started with `node dist/index.js`
# and its production node_modules is copied from the builder, so the npm CLI
# (and its vulnerable deps pacote/sigstore/picomatch) never ships. The trailing
# `microdnf update` applies the latest Rocky 9 security errata to packages baked
# into the base layer (curl 7.76.1-43 -> -44.el9_9.1 clears 14 highs; expat ->
# -9.el9_9.8) — it must run AFTER install so pre-installed base packages upgrade.
RUN microdnf module reset -y php nginx \
    && microdnf module enable -y nodejs:22 nginx:1.26 \
    && microdnf install --setopt=install_weak_deps=0 --nodocs -y \
    nodejs \
    ca-certificates \
    glibc-langpack-en \
    nginx \
    tzdata \
    && microdnf update --nodocs -y \
    && microdnf clean all \
    # The nodejs module bundles npm under /usr/lib/node_modules/npm; we never run
    # npm at runtime, so drop it (removes its deps pacote/sigstore/picomatch).
    && rm -rf /usr/lib/node_modules/npm /usr/bin/npm /usr/bin/npx

COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

COPY nginx.conf /etc/nginx/nginx.conf
RUN chown -R 1000:0 /var/lib/nginx /var/log/nginx

WORKDIR /app
COPY src/aap-mcp.sample.yaml /app/aap-mcp.yaml
# Production node_modules (dev-pruned, CVE-overrides applied) + dist + package.json
# straight from the builder — no npm install at runtime.
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY src/data/ ./data/
# "skills": bundle the public aap-skills SKILL.md packages + shared context
# at the paths the server reads — SKILLS_PATH (/app/skills) + SHARED_CONTEXT_PATH
# (/app/context). loadSkills() recurses these for SKILL.md. skills_enabled defaults
# to false upstream, so we flip SKILLS_ENABLED=true below (we ship the packages).
COPY skills/skills/ /app/skills/
COPY skills/context/ /app/context/
COPY --from=dumb_init_build /deps/dumb-init/dumb-init /usr/local/bin

USER 1000
EXPOSE 8086

ENV BASE_URL="" \
    NODE_ENV=production \
    MCP_PORT=3000 \
    IGNORE_CERTIFICATE_ERRORS="" \
    SESSION_TIMEOUT="1200" \
    ENABLE_METRICS="" \
    SKILLS_ENABLED="true" \
    SKILLS_PATH="/app/skills" \
    SHARED_CONTEXT_PATH="/app/context"

ENTRYPOINT ["/usr/local/bin/dumb-init", "--"]
CMD ["/entrypoint.sh"]
