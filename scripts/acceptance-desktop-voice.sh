#!/bin/bash
# Acceptance for the desktop-voice race fixes: the three failure scenes the
# review called out, each with a named regression in the isolated lifecycle
# package. Run before shipping voice-path changes that touch the uncertain-
# effect protocol, the tool-result follow-up, or screen-observation identity.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"

run_case() {
    local label="$1" filter="$2"
    if bash "$project_dir/scripts/test-stepfun-voice-lifecycle.sh" --filter "$filter" >/dev/null 2>&1; then
        echo "$label: PASS"
    else
        echo "$label: FAIL"
        exit 1
    fi
}

run_case "correction-after-uncertain" \
    "DesktopTaskCoordinatorTests/testCorrectionWithReplaceTargetExecutesTheNewTarget"
run_case "cancelled-followup-without-created" \
    "discardedFollowupNeverBlocksTheUsersNextResponse"
run_case "same-window-content-change" \
    "testSameWindowContentChangeIsRejected"
echo "stale answer rejected: confirmed by testSameWindowContentChangeIsRejected"
