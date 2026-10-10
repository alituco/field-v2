#!/usr/bin/env bash
# Fast, credential-free checks: run this locally before pushing CI/deploy edits.
set -euo pipefail
cd "$(dirname "$0")/../.."
for script in .github/scripts/*.sh; do
  bash -n "$script"
done
for script in .github/scripts/*.mjs; do
  node --check "$script"
done
node --test .github/scripts/*.test.mjs
