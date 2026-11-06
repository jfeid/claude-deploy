#!/usr/bin/env bash
# End-to-end checks of bin/deploy.sh against a fake Envoyer API and a fake ssh
# (tests/fake-envoyer/, put first on PATH) and a throwaway git repository, so the
# script can be tested on every platform CI offers (Linux, macOS, Windows/Git Bash).
#   bash tests/deploy-cli.sh
# Needs jq and git.
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
D="$HERE/bin/deploy.sh"
command -v jq >/dev/null 2>&1 || { echo "jq not found"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git not found"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Folders with a space, to catch unquoted paths.
export DEPLOY_HOME="$TMP/deploy home" FAKE_ENVOYER_DIR="$TMP/fake"
export DEPLOY_ID_INTERVAL=0 DEPLOY_POLL_INTERVAL=0 DEPLOY_RETRY_WAIT=0
export PATH="$HERE/tests/fake-envoyer:$PATH"
unset ENVOYER_API_TOKEN ENVOYER_URL DEPLOY_PROJECT_FILE FAKE_ENVOYER_FAIL FAKE_ENVOYER_LAG \
    FAKE_ENVOYER_STEPS FAKE_ENVOYER_RESULT DEPLOY_ID_WAIT DEPLOY_WAIT DEPLOY_NO_FETCH
mkdir -p "$FAKE_ENVOYER_DIR" "$DEPLOY_HOME"
# Envoyer tokens contain a |; the quote and backslash check the curl config escaping.
TOKEN='42|tok"en\abc'
export FAKE_ENVOYER_TOKEN="$TOKEN"
git() { command git -c user.name=CI -c user.email=ci@example.com -c init.defaultBranch=main "$@"; }

fails=0
out=""
run() {
    local name=$1 want=$2 code
    shift 2
    out=$(bash "$D" "$@" 2>&1 </dev/null); code=$?
    if [ "$code" = "$want" ]; then
        echo "ok   $name"
    else
        echo "FAIL $name: exit $code, expected $want"
        printf '%s\n' "$out" | sed 's/^/     /'
        fails=$((fails + 1))
    fi
}
has() {
    if printf '%s\n' "$out" | grep -qF -- "$1"; then
        echo "ok     has '$1'"
    else
        echo "FAIL   no '$1' in:"
        printf '%s\n' "$out" | sed 's/^/     /'
        fails=$((fails + 1))
    fi
}
hasnt() {
    if printf '%s\n' "$out" | grep -qF -- "$1"; then
        echo "FAIL   unexpected '$1' in:"
        printf '%s\n' "$out" | sed 's/^/     /'
        fails=$((fails + 1))
    else
        echo "ok     no '$1'"
    fi
}
requests() { out=$(cat "$FAKE_ENVOYER_DIR/requests.log" 2>/dev/null); }

# A project with an origin: main and staging, an old commit without the hash script.
git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/shop app" 2>/dev/null
cd "$TMP/shop app" || exit 1
echo one > assets.txt
git add . && git commit -qm "Old commit" && OLD=$(git rev-parse HEAD)
mkdir -p deploy
cat > deploy/asset-hash.sh <<'EOF'
#!/usr/bin/env bash
cd "$(dirname "${BASH_SOURCE[0]}")/.." && cksum < assets.txt | cut -d' ' -f1
EOF
git add . && git commit -qm "Add asset hash" && MAIN=$(git rev-parse HEAD)
git push -q origin main 2>/dev/null
git checkout -qb staging
echo two > assets.txt
git commit -qam "Staging work" && STAGING=$(git rev-parse HEAD)
git push -q origin staging 2>/dev/null
git checkout -q main

echo "== not configured"
run "config, nothing" 0 config;                    has "project_file_missing=1"; has "token=missing"
run "trigger, no project file" 1 trigger staging;  has "No $TMP/shop app/.claude/deploy.json"
run "help" 0 help;                                 has "deploy.sh trigger ENV"; has "The token and the hooks are never printed"

mkdir -p .claude
cat > .claude/deploy.json <<'EOF'
{
  "projects": { "staging": 101, "production": 102 },
  "hooks": { "staging": "hook-staging", "production": "" }
}
EOF
run "latest, no token" 1 latest staging;           has "No Envoyer API token"
jq -n --arg t "$TOKEN" '{api_token: $t}' > "$DEPLOY_HOME/config.json"
chmod 644 "$DEPLOY_HOME/config.json"

echo "== settings"
run "config" 0 config
has "default_environment=staging"; has "confirm=production"; has "environments=production,staging"
has "assets=no"; has "jira_sync=true"; has "token=file"; has "is not ignored by git"
echo ".claude/deploy.json" > .gitignore
run "config, ignored" 0 config;                    hasnt "warning="
run "envs" 0 envs
has "$(printf 'production\t102\tno-hook\tconfirm')"; has "$(printf 'staging\t101\thook\t-')"
run "check" 0 check
has 'staging: project 101 "Shop staging", branch staging, hook set'
has 'production: project 102 "Shop production", branch main, hook MISSING'; has "last: none"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) has "readable by other users" ;;
esac
chmod 600 "$DEPLOY_HOME/config.json"
run "check staging" 0 check staging;               hasnt "production:"; hasnt "readable by other"
run "projects" 0 projects;                         has "$(printf '102\tShop production\tmain')"
run "branch" 0 branch production;                  has "main"
run "latest, none" 0 latest staging;               has "No deployments yet."
run "url" 0 url staging;                           has "https://envoyer.io/projects/101"
run "unknown env" 1 latest qa;                     has "Known: production, staging"
run "no env" 1 latest;                             has "Name the environment"
run "odd env" 1 latest 'st;ag';                    has "Unknown environment"

echo "== trigger and wait"
run "trigger" 0 trigger staging
has "Triggered staging (project 101)"; has "id=501 status=queued commit=01234567 message=Deploy"; hasnt "second line"
run "latest" 0 latest staging;                     has "id=501"
run "wait" 0 wait staging 501;                     has "running"; has "status=finished"; has "FINAL_STATUS=finished"
run "status" 0 status staging 501;                 has "id=501 status=finished"
run "trigger sha" 0 trigger staging "sha:${STAGING:0:7}"; has "sha $STAGING"; has "id=502"
requests;                                          has "POST /deploy/hook-staging?sha=$STAGING auth=missing"
run "trigger branch" 0 trigger staging branch:feature/x-1; has "id=503"
requests;                                          has "POST /deploy/hook-staging?branch=feature%2Fx-1"
FAKE_ENVOYER_RESULT=error run "wait, error" 1 wait staging 503
has "FINAL_STATUS=error"; has "url=https://envoyer.io/projects/101"
FAKE_ENVOYER_LAG=100 DEPLOY_ID_WAIT=3 run "trigger, never listed" 3 trigger staging
has "no new deployment was listed within 3s"
rm -f "$FAKE_ENVOYER_DIR"/pending-* "$FAKE_ENVOYER_DIR"/lag-*
run "trigger again" 0 trigger staging;             has "id=504"
FAKE_ENVOYER_STEPS=100 run "wait, timeout" 2 wait staging 504 3; has "FINAL_STATUS=timeout"
run "wait, unknown id" 1 wait staging 999;         has "Deployment 999 not found"
run "wait, no id" 1 wait staging;                  has "Give the deployment id"
run "trigger, no hook" 1 trigger production;       has "No deploy hook for production"
jq '.hooks.production = "hook-wrong"' .claude/deploy.json > c.json && mv c.json .claude/deploy.json
run "trigger, wrong hook" 1 trigger production;    has "answered HTTP 404; nothing was deployed"
jq '.hooks.production = "bad hook"' .claude/deploy.json > c.json && mv c.json .claude/deploy.json
run "trigger, odd hook" 1 trigger production;      has "must be the hook id"; hasnt "bad hook"
jq '.hooks.production = "https://envoyer.io/deploy/hook-prod"' .claude/deploy.json > c.json && mv c.json .claude/deploy.json
run "trigger, hook URL" 0 trigger production;      has "id=501"
run "ref, unknown" 1 trigger staging main;         has "use sha:<commit> or branch:<name>"
run "ref, bad sha" 1 trigger staging sha:xyz;      has "sha: takes a commit hash"
run "ref, bad branch" 1 trigger staging 'branch:a b'; has "branch: takes a branch name"

echo "== errors"
FAKE_ENVOYER_TOKEN=other run "bad token" 1 latest staging; has "HTTP 401"
FAKE_ENVOYER_FAIL=500 run "server error" 1 latest staging; has "HTTP 500"
ENVOYER_API_TOKEN=env-token FAKE_ENVOYER_TOKEN=env-token run "env token" 0 latest staging; has "id=504"
ENVOYER_API_TOKEN=env-token run "config, env token" 0 config; has "token=env"
echo '{' > .claude/deploy.json.bad
DEPLOY_PROJECT_FILE=.claude/deploy.json.bad run "bad json" 1 envs; has "is not valid JSON"

echo "== token and hooks stay out of argv and output"
requests
hasnt "$TOKEN"
if grep -q 'argv=\[[^]]*hook-' "$FAKE_ENVOYER_DIR/requests.log"; then
    echo "FAIL   a hook in curl's argv"; fails=$((fails + 1))
else
    echo "ok     no hook in curl's argv"
fi

echo "== assets"
run "assets, none" 3 assets staging;               has "No assets block"
jq '.assets = {github_repo: "acme/shop", github_account: "acme", workflow: "build-assets.yml",
               ssh: {staging: "shop-dev", production: "down"}, cache_dir: "envoyer/assets cache/"}' \
    .claude/deploy.json > c.json && mv c.json .claude/deploy.json
run "config, assets" 0 config;                     has "assets=yes"
run "assets" 0 assets staging
has "github_repo=acme/shop"; has "ssh=shop-dev"; has "cache_dir=envoyer/assets cache/"; has "hash_script=deploy/asset-hash.sh"
jq 'del(.assets.ssh.production)' .claude/deploy.json > c.json && mv c.json .claude/deploy.json
run "assets, no ssh" 1 assets production;          has "assets.ssh.production"
jq '.assets.ssh.production = "down"' .claude/deploy.json > c.json && mv c.json .claude/deploy.json
run "resolve" 0 resolve staging;                   has "sha=$STAGING"; has "branch=staging"
run "resolve branch" 0 resolve staging branch:main; has "sha=$MAIN"; has "branch=main"
run "resolve sha" 0 resolve production "sha:${OLD:0:8}"; has "sha=$OLD"; has "branch=main"
run "resolve, no branch" 1 resolve staging branch:nope; has "No branch origin/nope"
DEPLOY_NO_FETCH=1 run "resolve, no fetch" 0 resolve production; has "sha=$MAIN"
before=$(git status --porcelain)
run "asset-hash" 0 asset-hash "$STAGING"
HASH=$(printf '%s\n' "$out" | sed -n 's/^hash=//p')
[ "$HASH" = "$(echo two | cksum | cut -d' ' -f1)" ] && echo "ok     hash of the commit's files" ||
    { echo "FAIL   hash '$HASH'"; fails=$((fails + 1)); }
[ "$(git status --porcelain)" = "$before" ] || { echo "FAIL   asset-hash touched the working tree"; fails=$((fails + 1)); }
run "asset-hash, old commit" 3 asset-hash "$OLD";  has "predates the CI asset build"
run "asset-hash, no commit" 1 asset-hash deadbeef; has "not found"
run "asset-check, missing" 1 asset-check staging "$HASH"; has "present=no"
mkdir -p "$FAKE_ENVOYER_DIR/server-shop-dev/envoyer/assets cache"
touch "$FAKE_ENVOYER_DIR/server-shop-dev/envoyer/assets cache/$HASH.tar.gz"
run "asset-check, present" 0 asset-check staging "$HASH"; has "present=yes"
run "asset-check, ssh down" 2 asset-check production "$HASH"; has "ssh down failed"
run "asset-check, odd hash" 1 asset-check staging 'x;rm'; has "Give the asset hash"

echo
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
