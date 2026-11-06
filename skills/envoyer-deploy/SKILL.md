---
name: envoyer-deploy
description: Deploy a project with Envoyer (envoyer.io) and follow it to the end. Triggers the deploy hook for an environment (staging by default, production after confirmation), optionally for a given commit or branch, waits for the deployment to finish and reports it. Optional steps make sure CI-built assets are on the server first and sync the Jira on-staging label afterwards. Also status, setup and help. Use for /deploy, or when the user asks to deploy to staging or production in a project with .claude/deploy.json.
argument-hint: "[ENVIRONMENT] [sha:<commit>|branch:<name>] | status [ENVIRONMENT] | setup | help"
user-invocable: false
allowed-tools: Bash(deploy.sh config:*) Bash(deploy.sh envs:*) Bash(deploy.sh check:*) Bash(deploy.sh projects:*) Bash(deploy.sh branch:*) Bash(deploy.sh latest:*) Bash(deploy.sh status:*) Bash(deploy.sh trigger:*) Bash(deploy.sh wait:*) Bash(deploy.sh url:*) Bash(deploy.sh assets:*) Bash(deploy.sh resolve:*) Bash(deploy.sh asset-hash:*) Bash(deploy.sh asset-check:*) Bash(deploy.sh help:*)
---

# Deploy with Envoyer

Trigger an Envoyer deployment and watch it until it ends. The plugin's
helper `deploy.sh` does the Envoyer calls; it is on the Bash tool's PATH
while the plugin is enabled. If the shell cannot find it, run
`${CLAUDE_PLUGIN_ROOT}/bin/deploy.sh` instead.

## Arguments

`$ARGUMENTS`: `[ENVIRONMENT] [sha:<commit>|branch:<name>]`, or an action.

- `/deploy`: deploy the default environment (`staging` unless the project
  sets `default_environment`) from the branch Envoyer deploys.
- `/deploy production`: deploy production (asks first).
- `/deploy staging sha:abc123`: deploy a given commit.
- `/deploy production branch:feature-x`: deploy a given branch.
- `/deploy status [ENVIRONMENT]`: the latest deployment of each environment,
  or of the one named. Read-only.
- `/deploy setup`: set up the token and the project file (below).
- `/deploy help`: show this list and stop.

## Secrets

The API token (`~/.claude/deploy/config.json` or `ENVOYER_API_TOKEN`) and
the deploy hooks (`hooks` in `.claude/deploy.json`) are secrets: a hook
deploys without any login. Never print, `cat`, read or echo either file,
never pass the token or a hook on a command line, and never ask the user to
paste them into the conversation. `deploy.sh config`, `envs` and `check`
show what is set without the values. Edit `.claude/deploy.json` only with
`jq` into a temporary file and `mv`, so the hooks stay unread.

## Deploy

1. **Settings.** Run `deploy.sh config`. It prints `default_environment`,
   `confirm` (environments that need a yes), `environments`, `assets`
   (yes/no), `jira_sync`, `token` (env/file/missing) and any `warning`.
   - `project_file_missing=1` or `token=missing`: say what is missing and
     offer `/deploy setup`. Stop.
   - A `warning` that the file is not git-ignored: tell the user and offer
     to add `.claude/deploy.json` to `.gitignore`, then go on.

2. **Arguments.** The first argument is the environment (default
   `default_environment`); the second, optional, is `sha:<commit>` or
   `branch:<name>`. An environment not in `environments`: ask which one,
   listing them. A bare commit hash or branch name as the second argument:
   ask whether it is a `sha:` or a `branch:`.

3. **Confirm.** For an environment in `confirm` (by default `production`),
   ask before going on, naming the environment, the Envoyer project and the
   sha or branch when given. Go on only on a clear yes.

4. **Assets built in CI** (only when `assets=yes`). See
   [Assets](#assets) below. When it stops, do not trigger Envoyer.

5. **Trigger.** `deploy.sh trigger ENV [sha:C|branch:B]`. It calls the
   hook, waits up to a minute for Envoyer to list the new deployment (it
   can take 20 s or more) and prints
   `id=<id> status=<status> commit=<8 chars> message=<subject>`.
   - Exit 3: the hook accepted the trigger but no deployment was listed.
     Report that with the Envoyer link from the message, and stop.
   - Exit 1: nothing was deployed; report the message.

6. **Wait.** `deploy.sh wait ENV ID` with the Bash tool's
   `run_in_background` (timeout 400000 ms). It polls every 10 s for up to
   5 minutes, prints each status change and ends with `FINAL_STATUS=`.
   Do not poll yourself; you are told when it ends.

7. **Report**, by `FINAL_STATUS`:
   - `finished`: deployed. One line with the environment, commit and
     message.
   - `error` (or `cancelled`): the deployment failed. Give the Envoyer link
     (`url=`) and suggest the deployment log there.
   - `timeout`: still running after 5 minutes. Give the link and offer
     `deploy.sh wait ENV ID` again.

8. **Jira label** (after `finished` only). When `jira_sync=true` and the
   `jira-worklog:jira-workflow` skill is in your list of available skills,
   load it with the arguments `staging` and follow it: it adds the
   `on-staging` label to tickets that just reached staging and removes it
   from tickets now on the base branch. Put its table under the deployment
   report. Skip this step without comment when the skill is not available,
   when the repository has no `origin/staging` branch, or when the Jira
   skill reports it is not set up.

## Assets

For projects whose client assets are built by a GitHub Actions workflow
and cached on each server as `<cache_dir>/<hash>.tar.gz`, where an Envoyer
hook installs them and fails the deploy when the tarball is missing. This
step makes sure the tarball is there before Envoyer is called.

`gh` and `ssh` need the system keyring and the network: run them, and
`deploy.sh asset-check`, with the sandbox disabled. Prefix every `gh` call
with `GH_TOKEN=$(gh auth token -u <github_account>)` when `github_account`
is set.

1. `deploy.sh assets ENV`: `github_repo`, `github_account`, `workflow`,
   `ssh`, `cache_dir`, `hash_script`.
2. `deploy.sh resolve ENV [sha:C|branch:B]`: fetches origin and prints
   `sha=` (the commit to deploy) and `branch=` (the given branch, else the
   branch of the Envoyer project).
3. `deploy.sh asset-hash SHA`: runs the commit's hash script on a copy of
   that commit (the working tree is not touched) and prints `hash=`. Exit 3:
   the commit predates the CI build; stop and say so.
4. `deploy.sh asset-check ENV HASH`: exit 0 present, go to step 6; exit 1
   missing, go to step 5; exit 2 SSH failed, stop and report.
5. Missing: look for a run of the workflow for the commit:
   `gh run list -R <github_repo> --workflow <workflow> --commit SHA --json databaseId,status,conclusion,event,headBranch,url,createdAt --limit 5`.
   A push can take up to a minute to be listed, so when the branch has a
   push trigger in the workflow and the commit was just pushed, poll every
   10 s for a minute.
   - A queued or running run: wait for it with
     `gh run watch <id> -R <github_repo> --exit-status` (Bash
     `run_in_background`, 15-minute timeout), then check again (step 4).
   - No run, or a finished run after which the tarball is still missing (a
     run may fill only another server's cache): start one,
     `gh workflow run <workflow> -R <github_repo> --ref <branch> -f ref=SHA -f servers=ENV`,
     find it with `gh run list ... --event workflow_dispatch --limit 1`
     once its `createdAt` is after the dispatch, watch it, then check again.
   - A failed run, or the tarball still missing after a successful one:
     stop, give the run URL, and do not trigger Envoyer.
6. One line before the trigger: `Assets <hash, 8 chars>: present on ENV`,
   plus the run URL when a build was waited for or started.

The workflow must accept `workflow_dispatch` inputs `ref` (the commit) and
`servers` (the environment whose cache to fill).

## status

`deploy.sh latest ENV` for the environment named, or for each one in
`deploy.sh envs`. One line each: environment, id, status, commit, message.

## setup

1. `deploy.sh config`.
2. **Token** (`token=missing`): the user creates an API token in Envoyer
   (profile, API) that can read projects and deployments, then saves it
   in a terminal of their own, outside this conversation:

   ```
   mkdir -p ~/.claude/deploy && chmod 700 ~/.claude/deploy
   read -rsp 'Envoyer API token: ' t && echo && (umask 077; jq -n --arg t "$t" '{api_token: $t}' > ~/.claude/deploy/config.json); unset t
   ```

   Or they set `ENVOYER_API_TOKEN`. Wait until they say it is done.
3. **Project file** (`project_file_missing=1`): `deploy.sh projects` lists
   the Envoyer projects. Ask which project is which environment, then write
   `.claude/deploy.json` in the repository root:

   ```json
   {
     "projects": { "staging": 114567, "production": 125616 },
     "hooks": { "staging": "", "production": "" }
   }
   ```

   Make sure `.claude/deploy.json` is in `.gitignore` (add it after asking).
   Then the user fills in each hook themselves: in Envoyer, the project's
   Deployment Hooks, the part of the URL after `/deploy/` (or the whole
   URL).
4. `deploy.sh check`: project names, branches, hooks set, last deployment.

Optional keys in `.claude/deploy.json`: `default_environment`
(default `staging`), `confirm` (environments that need a yes, default
`["production"]`), `jira_sync` (`false` turns step 8 off), `assets`.

## Rules

- Never trigger a deployment the user did not ask for, and never retry a
  failed trigger or deployment without asking.
- One deployment at a time: do not trigger while one of the same
  environment is still running (check with `deploy.sh latest ENV` when
  unsure).
- Envoyer's host must be reachable from the sandbox; when a call fails
  with "network, or the sandbox?", say so and mention `/sandbox`.
