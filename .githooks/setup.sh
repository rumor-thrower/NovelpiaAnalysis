#!/usr/bin/env bash
#
# One-time setup for this repo's git hooks. Run once per clone:
#   ./.githooks/setup.sh
#
# It (1) points git at the version-controlled hooks in .githooks/, and
# (2) installs JuliaFormatter v2 into the shared @juliaformatter environment
# so the pre-commit hook runs fast (no Pkg.add per commit).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "==> git config core.hooksPath .githooks"
git config core.hooksPath .githooks

if command -v julia >/dev/null 2>&1; then
    echo "==> Installing JuliaFormatter v2 into shared @juliaformatter env..."
    julia --startup-file=no -e '
        using Pkg
        Pkg.activate("@juliaformatter"; shared=true)
        Pkg.add(PackageSpec(name="JuliaFormatter", version="2"))
        using JuliaFormatter
        println("JuliaFormatter ready: ", pkgversion(JuliaFormatter))'
else
    echo "!! 'julia' not on PATH — install Julia, then re-run this script." >&2
fi

echo "==> Done. The pre-commit hook is now active."
