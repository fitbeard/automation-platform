#!/usr/bin/env bash
#
# extract-source-oci.sh — pull a materialized source tree out of a vendor BSI
# "-source" OCI image (replacement for the public SRPM, which no
# longer exists).
#
# A "-source" image is a build-source-image (BSI) container: OCI-layout, no
# runnable config, one source artifact per layer —
#   ./rpm_dir/<pkg>.src.rpm          (SRPMs of every RPM in the image)
#   ./extra_src_dir/extra-src-*.tar  (Cachi2 sources, incl. the app's Konflux
#                                     build-wrapper repo <name>-container-<sha>.tar.gz
#                                     with the private submodules MATERIALIZED)
# Every materialized app/DAB/UI tree inside the wrapper is Apache-2.0 / MPL-2.0
# (license-gated before use); the wrapper's own build glue is not vendored.
#
# Usage:
#   extract_source_oci <image> <workdir> [wrapper-glob]
#     <image>        the ...:<tag>-source image (must be pulled locally)
#     <workdir>      scratch dir to extract into (wiped)
#     [wrapper-glob] grep pattern for the build-wrapper tarball inside the
#                    extra-src tars (default: 'container.*\.tar\.gz')
#   Echoes the extracted wrapper root dir (which contains sources/ or the
#   materialized submodules at its top level) on stdout.
#
set -euo pipefail

extract_source_oci() {
    local image="$1" work="$2" glob="${3:-container.*\.tar\.gz}"
    rm -rf "$work"; mkdir -p "$work/layers" "$work/wrapper"

    if ! docker image inspect "$image" >/dev/null 2>&1; then
        echo "==> fetching source image (login to registry required first): $image" >&2
        docker pull "$image" >&2 || {
            echo "ERROR: could not fetch $image (needs registry auth)" >&2
            return 1
        }
    fi

    docker save "$image" -o "$work/img.tar"
    tar -xf "$work/img.tar" -C "$work/layers"

    # Each extra_src_dir layer blob is a gzipped tar holding extra-src-*.tar files.
    local b
    for b in "$work"/layers/blobs/sha256/*; do
        [ -f "$b" ] || continue
        if tar -tzf "$b" 2>/dev/null | grep -q 'extra_src_dir'; then
            tar -xzf "$b" -C "$work" 2>/dev/null || true
        fi
    done

    # Inside one of the extra-src tars is the app build-wrapper tarball.
    local t hit gz=""
    for t in "$work"/extra_src_dir/*.tar; do
        [ -f "$t" ] || continue
        hit=$(tar -tf "$t" 2>/dev/null | grep -iE "$glob" | head -1 || true)
        if [ -n "$hit" ]; then
            tar -xf "$t" -C "$work" "$hit" 2>/dev/null || true
            gz="$work/${hit#./}"
            break
        fi
    done
    [ -n "$gz" ] || { echo "ERROR: no build-wrapper tarball (glob: $glob) in $image" >&2; return 1; }

    tar -xzf "$gz" -C "$work/wrapper"
    local root
    root=$(find "$work/wrapper" -maxdepth 1 -mindepth 1 -type d | head -1)
    [ -n "$root" ] || { echo "ERROR: empty wrapper after extraction" >&2; return 1; }
    echo "$root"
}

# assert_submodule_license <wrapper-root> <subpath> [<subpath> ...]
#
# LICENSE GATE (hard rule: we publish only open-source). Fail the build unless
# EACH named materialized submodule carries a LICENSE/COPYING file at its root
# whose text matches a recognized OSS license (Apache-2.0 / MPL / BSD / MIT / GPL).
#
# Why this exists: the app source now comes from a vendor "-source" OCI, not a
# public repo we can inspect on GitHub. A future -source bump could silently drop
# a LICENSE or swap the tree for an unlicensed/relicensed one. Without this gate
# that would ship unnoticed; with it the build stops loudly at extraction time.
#
# APP builds (awx / eda / gateway) call this on their app + UI submodules. The
# gateway OPERATOR build deliberately does NOT — its operator glue ships no
# license, is built locally for testing only, and is never distributed (see the
# 2.7 distribution/license matrix).
assert_submodule_license() {
    local root="$1"; shift
    local sub lic hit
    for sub in "$@"; do
        # -type f: match a LICENSE/COPYING *file* only. Some downstream trees
        # (e.g. the controller's sources/tower) also carry a `licenses/` DIRECTORY
        # of per-dependency license texts next to the project's own LICENSE.md —
        # without -type f the dir name matches 'LICENSE*' and grep on it finds no
        # license, a false failure.
        lic=$(find "$root/$sub" -maxdepth 1 -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' \) 2>/dev/null | head -1)
        if [ -z "$lic" ]; then
            echo "LICENSE GATE FAIL: no LICENSE/COPYING at root of submodule '$sub'" >&2
            echo "  ($root/$sub) — refusing to build a DISTRIBUTABLE image from an" >&2
            echo "  unlicensed source tree. If this is intended (non-distributed), skip the gate." >&2
            return 1
        fi
        hit=$(grep -m1 -iE 'Apache License|Mozilla Public License|BSD |MIT License|GNU (GENERAL|LESSER) PUBLIC LICENSE' "$lic" 2>/dev/null || true)
        if [ -z "$hit" ]; then
            echo "LICENSE GATE FAIL: '$sub' LICENSE ($lic) is not a recognized OSS license." >&2
            echo "  Review it before distributing — the -source tree may have been relicensed." >&2
            return 1
        fi
        echo "   license OK: ${sub} -> $(echo "$hit" | sed -E 's/^ *//')"
    done
}

# Allow running directly for ad-hoc extraction / inspection:
#   ./extract-source-oci.sh <image> <workdir> [wrapper-glob]
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    extract_source_oci "$@"
fi
