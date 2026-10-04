#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$repo_dir/dist"

# `-j 4` keeps the compiler inside a modest thread budget; a shared CI box can
# otherwise exhaust its process limit mid-compile.
mojo build -j 4 --emit shared-lib "$repo_dir/src/capi.mojo" \
  -o "$repo_dir/dist/libmojo-libyaml.so"