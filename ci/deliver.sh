#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_OS:-} == Linux && ${GITHUB_REPOSITORY:-} == Pustoy-inside/playport ]] || exit 1
cd "$GITHUB_WORKSPACE"
case ${1:-} in
previous-failure)
    if python3 -c 'import json; raise SystemExit(0 if json.load(open("ci/build-request.json")).get("local_handoff") is True else 1)'; then
        python3 ci/private-handoff.py
        exit 0
    fi
    # The connector reads job logs but cannot download private binary assets.
    # Classify the app log internally. No private log content is printed.
    previous=$(python3 -c 'import json; v=json.load(open("ci/build-request.json")).get("diagnose_failure", 0); assert type(v) is int and v >= 0; print(v)')
    [[ $previous != 0 ]] || exit 0
    diagnostics="$GITHUB_WORKSPACE/.work/previous-failure"
    mkdir -p "$diagnostics"
    gh release download "personal-failure-$previous-1" --repo "$GITHUB_REPOSITORY" \
        --pattern ci-failure-logs.tar.gz --dir "$diagnostics" --clobber
    python3 ci/classify-app-log.py "$diagnostics/ci-failure-logs.tar.gz"
    ;;
records)
    git diff --quiet -- . ':!app/artifacts.tsv' ':!build/generated' || {
        echo 'The build changed source outside the generated manifests.' >&2; exit 1;
    }
    if ! git diff --quiet -- app/artifacts.tsv build/generated; then
        git add app/artifacts.tsv build/generated
        git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
            commit -m 'Record manifests from personal unsigned build'
        gh auth setup-git
        git push "https://github.com/$GITHUB_REPOSITORY.git" HEAD:main
    fi
    ;;
package)
    out=$(find .work/out -mindepth 1 -maxdepth 1 -type d -name '*-release-unsigned-*' | sort | tail -1)
    test -n "$out"
    delivery="$PLAYPORT_BUILD/delivery"
    mkdir -p "$delivery"
    ./pp source "$delivery/source" --build "$out"
    ./pp source "$delivery/source" --check
    ./pp notices "$delivery/notices"
    tar -C "$delivery" -cf "$delivery/Playport-source.tar" source
    tar -C "$delivery" -czf "$delivery/Playport-notices.tar.gz" notices
    cp "$out"/*.ipa "$delivery/"
    cp "$out/provenance.txt" "$delivery/"
    cat > "$delivery/INSTALL.txt" <<'EOF'
Personal unsigned Playport build. Compiled from the source in Playport-source.tar.
Install the IPA through iloader (or AltStore) with the same Apple account as the existing app.
Keep the JIT helper extension and Increased Memory Limit entitlement.
Upgrade in place: uninstalling Playport deletes its installed games and saves.
After installation, check Settings > Setup check > Increased Memory Limit: On.
The IPA passed host packaging checks; this build has not been tested on an iPhone.
The source bundle includes rebuild instructions, dependency source and licence notices.
EOF
    (cd "$delivery" && sha256sum *.ipa *.tar *.tar.gz provenance.txt INSTALL.txt > SHA256SUMS)
    tag="personal-ipa-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
    gh release create "$tag" --repo "$GITHUB_REPOSITORY" --target "$(git rev-parse HEAD)" \
        --draft --title "Personal unsigned Playport $GITHUB_RUN_ID" \
        --notes-file "$delivery/INSTALL.txt"
    gh release upload "$tag" "$delivery"/*.ipa "$delivery"/*.tar "$delivery"/*.tar.gz \
        "$delivery/provenance.txt" "$delivery/INSTALL.txt" "$delivery/SHA256SUMS" --repo "$GITHUB_REPOSITORY"
    echo "Unsigned IPA, matching source and notices saved to a private draft release." >> "$GITHUB_STEP_SUMMARY"
    ;;
failure)
    logs="$PLAYPORT_BUILD/ci-failure-logs.tar.gz"
    test -d .work/run/logs || exit 0
    if [[ -f .work/run/logs/app.log ]]; then
        python3 ci/classify-app-log.py .work/run/logs/app.log
    fi
    tar -czf "$logs" .work/run/logs
    tag="personal-failure-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
    gh release create "$tag" "$logs" --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" \
        --draft --title "Personal build diagnostics $GITHUB_RUN_ID" \
        --notes 'Build did not complete. No IPA is claimed. Contains unsigned hosted-runner build logs only.'
    ;;
*) exit 2 ;;
esac
