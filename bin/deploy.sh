#!/usr/bin/env bash
# Helper for the envoyer-deploy plugin (/deploy): Envoyer API calls, deploy hooks and
# the optional check that CI-built assets are on the server before a deploy.
#
# Settings:
#   deploy.sh config                   settings and files, never the token or hooks
#   deploy.sh envs                     environments of this project (TSV: name, project
#                                      id, hook|no-hook, confirm|-)
#   deploy.sh check [ENV]              token, project access, branch and last deployment
#   deploy.sh projects                 Envoyer projects the token sees (TSV: id, name, branch)
# Deploying:
#   deploy.sh branch ENV               the branch the Envoyer project deploys
#   deploy.sh latest ENV               the latest deployment (id= status= commit= message=)
#   deploy.sh status ENV ID            one deployment, same form
#   deploy.sh trigger ENV [sha:C|branch:B]
#                                      call the deploy hook, wait for the new deployment
#                                      to be listed (DEPLOY_ID_WAIT, 60 s) and print it;
#                                      exit 3 when none shows up
#   deploy.sh wait ENV ID [SECONDS]    poll every 10 s until the deployment ends (default
#                                      300 s); prints FINAL_STATUS=; exit 0 finished,
#                                      1 error or cancelled, 2 timeout
#   deploy.sh url ENV                  the project's page on Envoyer
# Assets built in CI (only with an "assets" block in .claude/deploy.json; exit 3 without):
#   deploy.sh assets ENV               the assets settings for ENV (key=value)
#   deploy.sh resolve ENV [sha:C|branch:B]
#                                      git fetch, then the commit and branch to deploy
#   deploy.sh asset-hash SHA           run the commit's hash script (hash_script, default
#                                      deploy/asset-hash.sh) on a git archive of it;
#                                      exit 3 when the commit has no such script
#   deploy.sh asset-check ENV HASH     is <cache_dir>/<HASH>.tar.gz on the ENV server?
#                                      exit 0 present, 1 missing, 2 ssh failed
#   deploy.sh help
#
# Files : .claude/deploy.json in the repository root (or DEPLOY_PROJECT_FILE): project ids,
#         deploy hooks, options. Keep it out of git: the hooks deploy without a login.
#         $DEPLOY_HOME/config.json (DEPLOY_HOME: ~/.claude/deploy): {"api_token": "..."},
#         or the ENVOYER_API_TOKEN environment variable.
# The token and the hooks are never printed and never in argv: curl reads them on stdin.

set -uo pipefail

ROOT="${DEPLOY_HOME:-$HOME/.claude/deploy}"
GLOBAL="$ROOT/config.json"
ENVOYER="${ENVOYER_URL:-https://envoyer.io}"
ENVOYER="${ENVOYER%/}"

die() { echo "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "deploy.sh needs jq (https://jqlang.org/download/)."
command -v curl >/dev/null 2>&1 || die "deploy.sh needs curl."
# jq on Windows writes CRLF line ends; drop the CR so values compare.
WINDOWS=""
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) WINDOWS=1; jq() { command jq "$@" | tr -d '\r'; } ;;
esac

# ---- files ----------------------------------------------------------------------

if [ -n "${DEPLOY_PROJECT_FILE:-}" ]; then
    PFILE="$DEPLOY_PROJECT_FILE"
else
    TOP=$(git rev-parse --show-toplevel 2>/dev/null) || TOP=""
    [ -n "$TOP" ] || TOP=$(pwd)
    PFILE="$TOP/.claude/deploy.json"
fi

need_project() {
    [ -f "$PFILE" ] || die "No $PFILE. Create it with the Envoyer project ids and deploy hooks (see the plugin's README)."
    jq -e 'type == "object"' "$PFILE" >/dev/null 2>&1 || die "$PFILE is not valid JSON."
}

env_names() { jq -r '(.projects // {}) | keys | join(", ")' "$PFILE"; }

# need_env ENV: sets ENV and PROJECT_ID, or dies naming the known environments.
ENV=""; PROJECT_ID=""
need_env() {
    need_project
    local e="${1:-}"
    [ -n "$e" ] || die "Name the environment: $(env_names)."
    case "$e" in *[!A-Za-z0-9_.-]*) die "Unknown environment '$e'. Known: $(env_names)." ;; esac
    PROJECT_ID=$(jq -r --arg e "$e" '(.projects[$e] // empty) | tostring' "$PFILE")
    [ -n "$PROJECT_ID" ] || die "Unknown environment '$e' in $PFILE. Known: $(env_names)."
    case "$PROJECT_ID" in *[!0-9]*) die "projects.$e in $PFILE must be the Envoyer project id (a number)." ;; esac
    ENV="$e"
}

token_source() {
    if [ -n "${ENVOYER_API_TOKEN:-}" ]; then echo env
    elif [ -n "$(jq -r '.api_token // empty' "$GLOBAL" 2>/dev/null)" ]; then echo file
    else echo missing; fi
}

token() {
    local t="${ENVOYER_API_TOKEN:-}"
    if [ -z "$t" ]; then
        [ -f "$GLOBAL" ] || die "No Envoyer API token: create $GLOBAL with {\"api_token\": \"...\"} (chmod 600) or set ENVOYER_API_TOKEN."
        t=$(jq -r '.api_token // empty' "$GLOBAL" 2>/dev/null) || die "$GLOBAL is not valid JSON."
        [ -n "$t" ] || die "$GLOBAL has no api_token."
    fi
    printf '%s' "$t" | tr -d '\r\n'
}

# A value for a double-quoted curl config line.
cq() { printf '%s' "$1" | sed 's/[\\"]/\\&/g'; }

# ---- HTTP -----------------------------------------------------------------------

# api PATH: GET $ENVOYER/api PATH; sets BODY and HTTP. Retries on 429, 5xx and no answer.
HTTP=000; BODY=""
api() {
    local path="$1" out tok try
    tok=$(token) || exit 1
    for try in 1 2 3; do
        out=$(printf 'header = "Authorization: Bearer %s"\n' "$(cq "$tok")" |
            curl -sS --max-time 30 -K - -H 'Accept: application/json' -w '\n%{http_code}' \
                "$ENVOYER/api$path") || out=$'\n000'
        HTTP="${out##*$'\n'}"
        BODY="${out%$'\n'*}"
        case "$HTTP" in
            429|5??|000) [ "$try" -lt 3 ] || break
                         sleep "${DEPLOY_RETRY_WAIT:-$((try * 5))}" ;;
            *) break ;;
        esac
    done
}

api_error() { printf '%s' "$BODY" | jq -r '.message // .error // empty' 2>/dev/null | cut -c1-300; }

# api_ok PATH: like api, but dies unless the answer is 2xx JSON.
api_ok() {
    api "$1"
    case "$HTTP" in
        2??) ;;
        401|403) die "Envoyer API $1: HTTP $HTTP (check the API token and its scopes) $(api_error)" ;;
        404) die "Envoyer API $1: HTTP 404 (wrong project or deployment id?)" ;;
        000) die "Envoyer API $1: no answer from $ENVOYER (network, or the sandbox?)" ;;
        *) die "Envoyer API $1 failed: HTTP $HTTP $(api_error)" ;;
    esac
    jq -e . >/dev/null 2>&1 <<< "$BODY" || die "Envoyer API $1: the answer is not JSON."
}

# One line for a deployment object at jq path $1 of BODY.
dep_line() {
    jq -r "$1"' | "id=\(.id) status=\(.status) commit=\((.commit_hash // "")[0:8]) message=\((.commit_message // "") | split("\n")[0] | gsub("\r"; "") | .[0:120])"' <<< "$BODY"
}

LATEST='(.deployments // []) | max_by(.id)'
latest_id() { jq -r "$LATEST | .id // empty" <<< "$BODY"; }

# ---- refs -----------------------------------------------------------------------

REF_KIND=""; REF_VAL=""
parse_ref() {
    case "${1:-}" in
        "") ;;
        sha:*)
            REF_KIND=sha; REF_VAL="${1#sha:}"
            case "$REF_VAL" in ""|*[!0-9a-fA-F]*) die "sha: takes a commit hash, got '$REF_VAL'." ;; esac ;;
        branch:*)
            REF_KIND=branch; REF_VAL="${1#branch:}"
            case "$REF_VAL" in ""|-*|*[!A-Za-z0-9._/-]*) die "branch: takes a branch name, got '$REF_VAL'." ;; esac ;;
        *) die "Unknown '$1': use sha:<commit> or branch:<name>." ;;
    esac
}

project_branch() {
    api_ok "/projects/$PROJECT_ID"
    jq -r '.project.branch // empty' <<< "$BODY"
}

# ---- commands -------------------------------------------------------------------

cmd_config() {
    echo "project_file=$PFILE"
    if [ -f "$PFILE" ]; then
        need_project
        jq -r '"default_environment=\(.default_environment // "staging")",
               "confirm=\((.confirm // ["production"]) | join(","))",
               "environments=\((.projects // {}) | keys | join(","))",
               "assets=\(if (.assets | type) == "object" then "yes" else "no" end)",
               "jira_sync=\(if .jira_sync == false then "false" else "true" end)"' "$PFILE"
        if git rev-parse --git-dir >/dev/null 2>&1 && ! git check-ignore -q "$PFILE" 2>/dev/null; then
            echo "warning=$PFILE is not ignored by git; add it to .gitignore, the hooks deploy without a login"
        fi
    else
        echo "project_file_missing=1"
    fi
    echo "global_config=$GLOBAL"
    echo "token=$(token_source)"
    echo "envoyer=$ENVOYER"
}

cmd_envs() {
    need_project
    jq -r '(.confirm // ["production"]) as $c | (.hooks // {}) as $h
        | (.projects // {}) | to_entries[] | .key as $k
        | [$k, (.value | tostring),
           (if ($h[$k] // "") != "" then "hook" else "no-hook" end),
           (if ($c | index([$k])) then "confirm" else "-" end)] | @tsv' "$PFILE"
}

cmd_check() {
    local envs e branch tok mode
    tok=$(token) || exit 1
    if [ "$(token_source)" = file ] && [ -z "$WINDOWS" ]; then
        mode=$(ls -l "$GLOBAL" | cut -c5-10)
        [ "$mode" = "------" ] || echo "warning: $GLOBAL is readable by other users; run chmod 600 on it"
    fi
    need_project
    if [ -n "${1:-}" ]; then envs="$1"; else envs=$(jq -r '(.projects // {}) | keys[]' "$PFILE"); fi
    for e in $envs; do
        need_env "$e"
        api_ok "/projects/$PROJECT_ID"
        branch=$(jq -r '.project.branch // ""' <<< "$BODY")
        printf '%s: project %s "%s", branch %s, hook %s\n' "$e" "$PROJECT_ID" \
            "$(jq -r '.project.name // ""' <<< "$BODY")" "${branch:-?}" \
            "$(jq -r --arg e "$e" 'if (.hooks[$e] // "") != "" then "set" else "MISSING" end' "$PFILE")"
        api_ok "/projects/$PROJECT_ID/deployments"
        if [ -n "$(latest_id)" ]; then echo "  last: $(dep_line "$LATEST")"; else echo "  last: none"; fi
    done
}

cmd_projects() {
    api_ok "/projects"
    jq -r '(.projects // [])[] | [(.id | tostring), (.name // ""), (.branch // "")] | @tsv' <<< "$BODY"
}

cmd_branch() {
    need_env "${1:-}"
    local b; b=$(project_branch) || exit 1
    [ -n "$b" ] || die "Envoyer reports no branch for project $PROJECT_ID."
    echo "$b"
}

cmd_latest() {
    need_env "${1:-}"
    api_ok "/projects/$PROJECT_ID/deployments"
    [ -n "$(latest_id)" ] || { echo "No deployments yet." >&2; return 0; }
    dep_line "$LATEST"
}

need_id() { case "${1:-}" in ""|*[!0-9]*) die "Give the deployment id (a number)." ;; esac; }

cmd_status() {
    need_env "${1:-}"; need_id "${2:-}"
    api_ok "/projects/$PROJECT_ID/deployments/$2"
    dep_line '.deployment'
}

hook_url() {
    local h
    h=$(jq -r --arg e "$ENV" '.hooks[$e] // empty' "$PFILE")
    [ -n "$h" ] || die "No deploy hook for $ENV: set hooks.$ENV in $PFILE (Envoyer, project, Deployment Hooks)."
    case "$h" in
        https://*) printf '%s' "$h" ;;
        http://*|*[!A-Za-z0-9_-]*) die "hooks.$ENV in $PFILE must be the hook id or its https URL." ;;
        *) printf '%s/deploy/%s' "$ENVOYER" "$h" ;;
    esac
}

cmd_trigger() {
    need_env "${1:-}"; parse_ref "${2:-}"
    local url query="" prev out code full tries i=0
    local wait="${DEPLOY_ID_WAIT:-60}" interval="${DEPLOY_ID_INTERVAL:-5}"
    url=$(hook_url) || exit 1
    # A short sha the local repository knows goes to Envoyer in full.
    if [ "$REF_KIND" = sha ] && full=$(git rev-parse --verify --quiet "$REF_VAL^{commit}" 2>/dev/null); then
        REF_VAL="$full"
    fi
    [ -n "$REF_KIND" ] && query="?$REF_KIND=$(jq -rn --arg v "$REF_VAL" '$v | @uri')"
    # The newest id before the trigger: Envoyer can take 20 s or more to list the new one.
    api_ok "/projects/$PROJECT_ID/deployments"
    prev=$(latest_id); prev="${prev:-0}"
    out=$(printf 'url = "%s"\n' "$(cq "$url$query")" |
        curl -sS --max-time 30 -K - -X POST -w '\n%{http_code}') || out=$'\n000'
    code="${out##*$'\n'}"
    case "$code" in
        2??) ;;
        000) die "The deploy hook for $ENV did not answer (network, or the sandbox?). Nothing was deployed." ;;
        *) die "The deploy hook for $ENV answered HTTP $code; nothing was deployed. Check hooks.$ENV in $PFILE." ;;
    esac
    echo "Triggered $ENV (project $PROJECT_ID${REF_KIND:+, $REF_KIND $REF_VAL}); waiting for Envoyer to list it."
    if [ "$interval" -gt 0 ]; then tries=$(( (wait + interval - 1) / interval )); else tries="$wait"; fi
    while [ "$i" -lt "$tries" ]; do
        i=$((i + 1))
        sleep "$interval"
        api "/projects/$PROJECT_ID/deployments"
        case "$HTTP" in 2??) ;; *) continue ;; esac
        full=$(latest_id 2>/dev/null)
        if [ -n "$full" ] && [ "$full" -gt "$prev" ] 2>/dev/null; then
            dep_line "$LATEST"
            return 0
        fi
    done
    echo "The hook accepted the trigger (HTTP $code), but no new deployment was listed within ${wait}s. Check $ENVOYER/projects/$PROJECT_ID" >&2
    exit 3
}

cmd_wait() {
    need_env "${1:-}"; need_id "${2:-}"
    local id="$2" max="${3:-${DEPLOY_WAIT:-300}}" interval="${DEPLOY_POLL_INTERVAL:-10}"
    local n i=0 status last="" elapsed=0
    case "$max" in ""|*[!0-9]*) die "SECONDS must be a number." ;; esac
    if [ "$interval" -gt 0 ]; then n=$(( (max + interval - 1) / interval )); else n="$max"; fi
    [ "$n" -ge 1 ] || n=1
    while [ "$i" -lt "$n" ]; do
        i=$((i + 1))
        sleep "$interval"; elapsed=$((elapsed + interval))
        api "/projects/$PROJECT_ID/deployments/$id"
        case "$HTTP" in
            2??) status=$(jq -r '.deployment.status // "unknown"' <<< "$BODY" 2>/dev/null) ;;
            404) die "Deployment $id not found in project $PROJECT_ID." ;;
            401|403) die "Envoyer API: HTTP $HTTP (check the API token) $(api_error)" ;;
            *) status="unreachable (HTTP $HTTP)" ;;
        esac
        [ "$status" = "$last" ] || echo "[${elapsed}s] $status"
        last="$status"
        case "$status" in
            finished)
                dep_line '.deployment'; echo "FINAL_STATUS=finished"; exit 0 ;;
            error|failed|cancelled|canceled)
                dep_line '.deployment'; echo "url=$ENVOYER/projects/$PROJECT_ID"
                echo "FINAL_STATUS=$status"; exit 1 ;;
        esac
    done
    echo "url=$ENVOYER/projects/$PROJECT_ID"
    echo "FINAL_STATUS=timeout"
    exit 2
}

cmd_url() { need_env "${1:-}"; echo "$ENVOYER/projects/$PROJECT_ID"; }

# ---- assets -----------------------------------------------------------------------

need_assets() {
    jq -e '(.assets | type) == "object"' "$PFILE" >/dev/null 2>&1 ||
        { echo "No assets block in $PFILE: there is no asset step." >&2; exit 3; }
}

# asset VALUE_PATH: one setting of the assets block for ENV.
asset() { jq -r --arg e "$ENV" ".assets | $1 // empty" "$PFILE"; }

cmd_assets() {
    need_env "${1:-}"; need_assets
    local missing="" k
    for k in github_repo workflow cache_dir; do
        [ -n "$(asset ".$k")" ] || missing="$missing assets.$k"
    done
    [ -n "$(asset '.ssh[$e]')" ] || missing="$missing assets.ssh.$ENV"
    [ -z "$missing" ] || die "Missing in $PFILE:$missing"
    echo "github_repo=$(asset .github_repo)"
    echo "github_account=$(asset .github_account)"
    echo "workflow=$(asset .workflow)"
    echo "ssh=$(asset '.ssh[$e]')"
    echo "cache_dir=$(asset .cache_dir)"
    echo "hash_script=$(asset '.hash_script // "deploy/asset-hash.sh"')"
}

cmd_resolve() {
    need_env "${1:-}"; parse_ref "${2:-}"
    local sha branch
    git rev-parse --git-dir >/dev/null 2>&1 || die "Not in a git repository."
    if [ "${DEPLOY_NO_FETCH:-}" != 1 ]; then
        git fetch --quiet origin || die "git fetch origin failed (network, or the sandbox?)."
    fi
    case "$REF_KIND" in
        sha)
            sha=$(git rev-parse --verify --quiet "$REF_VAL^{commit}") || die "Commit $REF_VAL not found."
            branch=$(project_branch) || exit 1 ;;
        branch)
            branch="$REF_VAL"
            sha=$(git rev-parse --verify --quiet "origin/$branch^{commit}") || die "No branch origin/$branch." ;;
        *)
            branch=$(project_branch) || exit 1
            [ -n "$branch" ] || die "Envoyer reports no branch for project $PROJECT_ID."
            sha=$(git rev-parse --verify --quiet "origin/$branch^{commit}") || die "No branch origin/$branch." ;;
    esac
    echo "sha=$sha"
    echo "branch=$branch"
}

cmd_asset_hash() {
    local sha="${1:-}" script="deploy/asset-hash.sh" tmp h rc
    [ -n "$sha" ] || die "Usage: deploy.sh asset-hash SHA"
    if [ -f "$PFILE" ]; then
        h=$(jq -r '.assets.hash_script // empty' "$PFILE" 2>/dev/null)
        [ -n "$h" ] && script="$h"
    fi
    git cat-file -e "$sha^{commit}" 2>/dev/null || die "Commit $sha not found."
    if ! git cat-file -e "$sha:$script" 2>/dev/null; then
        echo "Commit ${sha:0:8} has no $script: it predates the CI asset build." >&2
        exit 3
    fi
    tmp=$(mktemp -d)
    if ! git archive "$sha" | tar -x -C "$tmp"; then rm -rf "$tmp"; die "git archive $sha failed."; fi
    h=$(bash "$tmp/$script"); rc=$?
    rm -rf "$tmp"
    [ "$rc" = 0 ] && [ -n "$h" ] || die "$script failed (exit $rc)."
    case "$h" in *[!A-Za-z0-9._-]*) die "$script printed an unexpected hash." ;; esac
    echo "hash=$h"
}

# A word for the remote shell, in single quotes.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

cmd_asset_check() {
    need_env "${1:-}"; need_assets
    local hash="${2:-}" host dir rc
    case "$hash" in ""|*[!A-Za-z0-9._-]*) die "Give the asset hash (from deploy.sh asset-hash)." ;; esac
    host=$(asset '.ssh[$e]'); dir=$(asset .cache_dir)
    [ -n "$host" ] && [ -n "$dir" ] || die "Set assets.ssh.$ENV and assets.cache_dir in $PFILE."
    case "$host" in -*) die "assets.ssh.$ENV must be an ssh host or alias." ;; esac
    ssh -o ConnectTimeout="${DEPLOY_SSH_TIMEOUT:-15}" -o BatchMode=yes "$host" \
        "timeout 20 test -f $(sq "${dir%/}/$hash.tar.gz")"
    rc=$?
    case "$rc" in
        0) echo "present=yes"; exit 0 ;;
        1) echo "present=no"; exit 1 ;;
        *) echo "ssh $host failed (exit $rc)." >&2; exit 2 ;;
    esac
}

# ---- main -------------------------------------------------------------------------

CMD="${1:-help}"
[ $# -gt 0 ] && shift
case "$CMD" in
    config)      cmd_config ;;
    envs)        cmd_envs ;;
    check)       cmd_check "$@" ;;
    projects)    cmd_projects ;;
    branch)      cmd_branch "$@" ;;
    latest)      cmd_latest "$@" ;;
    status)      cmd_status "$@" ;;
    trigger)     cmd_trigger "$@" ;;
    wait)        cmd_wait "$@" ;;
    url)         cmd_url "$@" ;;
    assets)      cmd_assets "$@" ;;
    resolve)     cmd_resolve "$@" ;;
    asset-hash)  cmd_asset_hash "$@" ;;
    asset-check) cmd_asset_check "$@" ;;
    help|-h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0" ;;
    *) die "Unknown command: $CMD (try: deploy.sh help)" ;;
esac
