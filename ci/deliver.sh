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
        git push "https://github.com/$GITHUB_REPOSITORY.git" "HEAD:$GITHUB_REF_NAME"
    fi
    ;;
package)
    out=$(find .work/out -mindepth 1 -maxdepth 1 -type d -name '*-release-unsigned-*' | sort | tail -1)
    test -n "$out"
    delivery="$PLAYPORT_BUILD/delivery"
    mkdir -p "$delivery"
    # The owner's name for a build: Playport Dishnur <n>, n from ci/build-request.json
    # ("build", else "request").
    number=$(jq -r '.build // .request' ci/build-request.json)
    title="Playport Dishnur $number"
    cp "$out"/*.ipa "$delivery/Playport-Dishnur-$number.ipa"
    cp "$out/provenance.txt" "$delivery/" 2>/dev/null || git rev-parse HEAD > "$delivery/provenance.txt"
    {
        echo "$title: a personal unsigned Playport build, from this fork's source at the commit this release targets."
        echo "Install the IPA through iloader (or AltStore) with the same Apple account as the existing app."
        echo "Keep the JIT helper extension and Increased Memory Limit entitlement."
        echo "Upgrade in place: uninstalling Playport deletes its installed games and saves."
        echo "After installation, check Settings > Setup check > Increased Memory Limit: On."
        echo "The IPA passed host packaging checks (verify-ipa); this build has not been tested on an iPhone."
    } > "$delivery/INSTALL.txt"
    (cd "$delivery" && sha256sum ./*.ipa provenance.txt INSTALL.txt > SHA256SUMS)
    tag="personal-ipa-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
    # The IPA first: it is what the run is for.
    gh release create "$tag" --repo "$GITHUB_REPOSITORY" --target "$(git rev-parse HEAD)" \
        --draft --title "$title" \
        --notes-file "$delivery/INSTALL.txt"
    gh release upload "$tag" "$delivery"/*.ipa "$delivery/provenance.txt" "$delivery/INSTALL.txt" \
        "$delivery/SHA256SUMS" --repo "$GITHUB_REPOSITORY"
    echo "Unsigned IPA saved to a private draft release." >> "$GITHUB_STEP_SUMMARY"
    # Then the matching source bundle and notices, best effort (the fork is public
    # source too); their log goes to the release either way.
    if { ./pp source "$delivery/source" --build "$out" &&
         ./pp source "$delivery/source" --check &&
         ./pp notices "$delivery/notices"; } > "$delivery/package.log" 2>&1; then
        tar -C "$delivery" -cf "$delivery/Playport-source.tar" source
        tar -C "$delivery" -czf "$delivery/Playport-notices.tar.gz" notices
        gh release upload "$tag" "$delivery/Playport-source.tar" "$delivery/Playport-notices.tar.gz" \
            --repo "$GITHUB_REPOSITORY"
    else
        echo "The source bundle or notices did not complete (package.log in the release)." >> "$GITHUB_STEP_SUMMARY"
    fi
    gh release upload "$tag" "$delivery/package.log" --repo "$GITHUB_REPOSITORY" --clobber
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
