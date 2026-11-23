#!/usr/bin/env bash
#
# Apply our local patches on top of the upstream ansible-ai-connect-operator
# checkout produced by build.sh (git clone + checkout of the pinned baseline).
#
# Patches live in ./patches/ as git-format-patch mailbox files. They're
# applied with `git am --3way`, which means:
#
#   - Each patch becomes a real commit visible in `git log` inside src/
#     (authorship, subject, body preserved from the original commit).
#   - If upstream drift prevents a clean apply, `--3way` attempts a
#     merge; if that fails too, `git am` aborts cleanly and leaves src/
#     in a reviewable state (run `git am --abort` to reset).
#
# Think of this as our `downstreamify.sh` — but transparent, git-native,
# and designed to surface upstream drift loudly instead of silently
# corrupting files with sed substitutions.
#
# Usage:
#   ./patch.sh                        # Apply all patches/*.patch
#   ./patch.sh --dry-run              # git am --check-equivalent (no side effects)
#   ./patch.sh --list                 # Show patches that would apply
#
# To author a new patch:
#   1. ./build.sh --prep-only         # fresh src/ with cherry-picks
#   2. cd src/ && edit files
#   3. cd src/ && git add -A && git commit -m "patch: <subject>"
#   4. cd src/ && git format-patch -1 HEAD --no-signature -o ../patches/
#   5. (optional) rename the file if you want stable ordering
#
# Drop a patch by deleting its file; list order is lexical
# (0001-, 0002-, ...).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"
PATCHES_DIR="${SCRIPT_DIR}/patches"

DRY_RUN=0
LIST_ONLY=0

for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=1 ;;
        --list)       LIST_ONLY=1 ;;
        -h|--help)    sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if [[ ! -d "${PATCHES_DIR}" ]]; then
    echo "==> No patches/ directory — nothing to apply"
    exit 0
fi

shopt -s nullglob
PATCH_FILES=("${PATCHES_DIR}"/*.patch)
shopt -u nullglob

if [[ ${#PATCH_FILES[@]} -eq 0 ]]; then
    echo "==> patches/ is empty — nothing to apply"
    exit 0
fi

echo "==> Found ${#PATCH_FILES[@]} patch(es):"
for p in "${PATCH_FILES[@]}"; do
    subject="$(grep -m1 '^Subject:' "$p" | sed 's/^Subject: \[PATCH[^]]*\] //')"
    printf '    %s  %s\n' "$(basename "$p")" "$subject"
done

if [[ $LIST_ONLY -eq 1 ]]; then
    exit 0
fi

if [[ ! -d "${SRC_DIR}/.git" ]]; then
    echo "ERROR: ${SRC_DIR} is not a git repo. Run ./build.sh --prep-only first." >&2
    exit 1
fi

cd "${SRC_DIR}"

# If there's an in-progress `git am` from a prior failed run, abort it
# so we start clean.
if [[ -d .git/rebase-apply ]]; then
    echo "==> Found incomplete git am state — aborting it"
    git am --abort || true
fi

if [[ $DRY_RUN -eq 1 ]]; then
    echo "==> Dry-run: checking each patch applies cleanly"
    for p in "${PATCH_FILES[@]}"; do
        if ! git apply --check "$p" 2>/dev/null; then
            echo "    FAIL  $(basename "$p")"
            git apply --check "$p" 2>&1 | sed 's/^/          /'
            exit 1
        fi
        echo "    OK    $(basename "$p")"
    done
    echo "==> All patches apply cleanly"
    exit 0
fi

echo "==> Applying patches with git am --3way"
if ! git am --3way --keep-cr "${PATCH_FILES[@]}"; then
    echo "" >&2
    echo "ERROR: patch application failed." >&2
    echo "  - Inspect conflict:    cd $(realpath --relative-to="$PWD" "$SRC_DIR") && git status" >&2
    echo "  - Skip this patch:     git am --skip" >&2
    echo "  - Reset and bail out:  git am --abort" >&2
    exit 1
fi

echo "==> Done. src/ HEAD now at $(git rev-parse --short HEAD)"
