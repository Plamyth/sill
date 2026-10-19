#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
if [[ $# -ne 1 ]]; then
    echo "usage: run.sh NEW_PARENT_RAM_OUTPUT" >&2
    exit 2
fi
exec python3 -B "$here/run.py" "$root" "$1"
