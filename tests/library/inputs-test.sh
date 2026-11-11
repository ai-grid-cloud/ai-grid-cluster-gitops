#!/usr/bin/env bash
# Checks that the library holds no deployment's values and that every input a
# deployment supplies reaches every component (tests/library/inputs_test.py).
# Needs python3 with PyYAML and kustomize. Touches no cluster.
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec python3 "$HERE/inputs_test.py" "$@"
