#!/bin/bash
# Run the Her E2E runner self-tests (no app, no provider, no desktop).
# These are the tests that must stay green before any acceptance evidence is
# produced: fixture behavior, probe plumbing, evidence schema, judges,
# dry-run consistency and process/secret hygiene.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
exec python3 "$project_dir/scripts/acceptance/her_voice_e2e.py" --self-test "$@"
