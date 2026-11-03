#!/usr/bin/env bash
# publish-app.sh — Shared "publish a .app to a running BC instance" helper.
#
# Designed to be SOURCED, not executed:
#
#   . "$REPO_DIR/scripts/publish-app.sh"
#   bc_publish_app /path/to/myapp.app
#   bc_publish_app /path/to/myapp.app "http://localhost:7049/BC/dev" "BCRUNNER:Admin123!"
#
# Returns 0 on success — meaning either:
#   - HTTP 200 (fresh publish completed), or
#   - HTTP 422 whose body says the extension is already deployed/installed/
#     published (BC reports that as a 422 even though it isn't a real
#     error).
#
# Returns 1 (and prints a diagnostic dump) for everything else, including
# any other 4xx/5xx and 422s that don't match one of those specific benign
# phrases. The most common 422 failure is "missing dependency" — when the
# .app declares a dependency on another extension that isn't installed in
# the BC database. The pre-2026 version of this code treated ALL 422s as
# "already installed" and silently swallowed missing-dep failures, which
# made for many wasted debugging cycles in downstream consumers like
# bc-copilot-blueprint. Now those failures are loud and have a clear
# error body printed.
#
# A later version of this code matched any 422 body containing the bare
# substring "already" — too loose. A genuine install-time AL failure can
# say e.g. "The record in table Install Seed already exists", which isn't
# benign at all: BC's error message says "The original extensions have
# been restored" (i.e. the publish was rolled back), but the bare-substring
# check treated it as success anyway, so the app was silently never
# installed and every subsequent test-codeunit lookup failed with
# "not found".
#
# So: match BC's known benign phrasings (already deployed/installed/
# published/exists, or "duplicate package ID" — the latter is what a
# republish of an identical already-published package looks like, e.g.
# run-tests.sh re-publishing a test app the workflow's earlier "Publish AL
# apps" step already published), but explicitly exclude any body that says
# the publish itself failed (BC wraps genuine install-trigger errors in
# "Publishing failed due to 'Could not install the extension ...'" and
# "The original extensions have been restored") even if that body also
# happens to contain one of the benign words.

bc_publish_app() {
    local app="$1"
    local dev_url="${2:-http://localhost:7049/BC/dev}"
    local auth="${3:-${BC_SERVER_USERNAME:-BCRUNNER}:${BC_SERVER_PASSWORD:-Admin123!}}"

    if [ -z "$app" ]; then
        echo "bc_publish_app: missing required argument: <app-path>" >&2
        return 1
    fi
    if [ ! -f "$app" ]; then
        echo "bc_publish_app: file not found: $app" >&2
        return 1
    fi

    # How long curl waits for the dev endpoint to answer. BC does not stop at
    # our limit: curl gives up, the publish goes on inside the tier, and the
    # job fails anyway. The limit is there to end a publish that hangs, and the
    # job's own timeout still applies. 600s stopped being enough in 2026-11:
    # the AL language corpus app took 280-594s on all of BC 27.5, 28.5 and 29.0
    # and went over on some runs (issue #206). BC_PUBLISH_TIMEOUT overrides it;
    # the reusable workflows expose that as the publish_timeout input.
    local max_time="${BC_PUBLISH_TIMEOUT:-1200}"

    local body
    body=$(mktemp)
    local code started elapsed curl_exit=0
    started=$(date +%s)
    code=$(curl -s -o "$body" -w "%{http_code}" --max-time "$max_time" \
        -u "$auth" -X POST \
        -F "file=@${app};type=application/octet-stream" \
        "${dev_url}/apps?SchemaUpdateMode=forcesync" 2>/dev/null) || curl_exit=$?
    elapsed=$(( $(date +%s) - started ))
    # Logged for every publish, so the margin to the limit shows in the log
    # before it is used up.
    echo "  publish $(basename "$app"): HTTP $code after ${elapsed}s (limit ${max_time}s)" >&2

    if [ "$code" = "200" ]; then
        rm -f "$body"
        return 0
    fi

    # curl exit 28 is its own timeout. Do not test the HTTP code for this: curl
    # reports the last status it saw, which is 100 once BC has answered
    # "Expect: 100-continue" and 000 before that.
    if [ "$curl_exit" = "28" ]; then
        echo ""
        echo "ERROR: no answer from the dev endpoint within ${max_time}s for $(basename "$app")"
        echo "       The publish may still be running inside BC. Raise"
        echo "       BC_PUBLISH_TIMEOUT (the publish_timeout input of the reusable"
        echo "       workflows) if this app is known to publish slowly."
        echo ""
        rm -f "$body"
        return 1
    fi

    if [ "$code" = "422" ] \
        && grep -qiE "already (deployed|installed|published|exists)|duplicate package" "$body" \
        && ! grep -qiE "publishing failed|could not install the extension|original extensions have been restored" "$body"; then
        rm -f "$body"
        return 0
    fi

    echo ""
    echo "ERROR: dev endpoint returned HTTP $code for $(basename "$app")"
    echo "       URL: ${dev_url}/apps?SchemaUpdateMode=forcesync"
    echo "       Body:"
    sed 's/^/         /' "$body"
    echo ""

    # Full-Text Search is the one failure mode whose follow-on error points
    # somewhere completely wrong: the app never installs, and everything
    # depending on it then fails with AL1024 "symbols could not be found",
    # which sends people digging through .alpackages and stage-symbols.py.
    # Name it explicitly. No official SQL Server Linux image ships FTS.
    if grep -qi "Full-Text Search component is not installed" "$body"; then
        echo "       CAUSE: this app uses AL's OptimizeForTextSearch, which needs the"
        echo "              SQL Server Full-Text Search component. No official SQL"
        echo "              Server Linux image ships it, so the default SQL container"
        echo "              can't install the app."
        echo ""
        echo "       FIX:   switch to the FTS-capable SQL image:"
        echo "                BC_SQL_IMAGE=ghcr.io/aldevtools/msdyn365bc.on.linux/mssql:2022-fts"
        echo "              or, in the reusable workflows:"
        echo "                sql_image: ghcr.io/aldevtools/msdyn365bc.on.linux/mssql:2022-fts"
        echo "              It is not the default because FTS adds ~550 MB to the"
        echo "              SQL image. See KNOWN-LIMITATIONS.md."
        echo ""
        echo "       NOTE:  apps that depend on this one will fail next with"
        echo "              'AL1024 ... symbols could not be found'. That is a"
        echo "              follow-on symptom, not a symbol-staging problem."
        rm -f "$body"
        return 1
    fi

    echo "       Common causes:"
    echo "         - Missing dependency that isn't installed in BC. (Putting"
    echo "           the symbol file in .alpackages makes it visible at"
    echo "           compile time, but the dependency itself still needs to"
    echo "           be installed in the BC database. If this is a Microsoft"
    echo "           test framework app, it may need to be added to the"
    echo "           republish set in entrypoint.sh.)"
    echo "         - Schema sync failure (forcesync detected a destructive"
    echo "           change in a published version)."
    echo "         - Version conflict with a previously-published variant."
    rm -f "$body"
    return 1
}
