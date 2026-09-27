#!/bin/sh
set -eu

# Intentionally no curl | sh, sudo, global package installs, or permission edits.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if ! command -v bun >/dev/null 2>&1; then
  echo 'Bun is required. Install the documented prerequisites, then retry.' >&2
  echo "See $script_dir/../docs/BUILDING.md" >&2
  exit 1
fi
exec bun "$script_dir/setup.ts" "$@"
