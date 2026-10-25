#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# progress.sh COMMAND...: run COMMAND and, every few minutes while it runs,
# put a short progress report (the newest build logs' tails) in an owner-only
# draft release, so the build can be followed without the Actions log API.
# The report holds hosted-runner build logs only: no SDK, keys or credentials.
set -uo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_OS:-} == Linux && ${GITHUB_REPOSITORY:-} == Pustoy-inside/playport ]] || exit 1
cd "$GITHUB_WORKSPACE"
tag="personal-progress-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
report="$GITHUB_WORKSPACE/.work/progress.txt"
mkdir -p "$(dirname "$report")"

# Older progress drafts are superseded by this run's.
gh api "repos/$GITHUB_REPOSITORY/releases?per_page=100" \
    --jq '.[] | select(.draft and (.tag_name | startswith("personal-progress-"))) | .tag_name' |
    while IFS= read -r old; do gh release delete "$old" --repo "$GITHUB_REPOSITORY" --yes || true; done
gh release create "$tag" --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" --draft \
    --title "Personal build progress $GITHUB_RUN_ID" \
    --notes 'Progress of a running hosted-runner build: tails of its logs. Not an installable IPA.' || true

write_report() {
    {
        echo "run $GITHUB_RUN_ID attempt $GITHUB_RUN_ATTEMPT, $(date -u +%FT%TZ), state: $1"
        echo "--- disk"; df -h . | tail -1
        echo "--- memory"; free -m | sed -n 2p
        echo "--- stamps (newest first)"; ls -t .work/run/stamps 2>/dev/null | head -40
        echo "--- logs (newest first)"; ls -lt .work/run/logs 2>/dev/null | head -15
        local f
        for f in $(ls -t .work/run/logs/*.log 2>/dev/null | head -3); do
            echo "=== tail $f"; tail -n 80 "$f"
        done
    } > "$report" 2>&1
    gh release upload "$tag" "$report" --repo "$GITHUB_REPOSITORY" --clobber >/dev/null 2>&1 || true
}

"$@" &
pid=$!
while kill -0 "$pid" 2>/dev/null; do
    write_report running
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 10; done
done
wait "$pid"
status=$?
write_report "exited $status"
exit "$status"
