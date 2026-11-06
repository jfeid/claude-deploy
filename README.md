# ![Envoyer Deploy icon](docs/icon-40.png) Claude Code Envoyer deploy

[![test](https://github.com/jfeid/claude-deploy/actions/workflows/test.yml/badge.svg)](https://github.com/jfeid/claude-deploy/actions/workflows/test.yml)

Envoyer Deploy (`envoyer-deploy`) is a Claude Code plugin that deploys a
project with [Envoyer](https://envoyer.io) and stays with the deployment
until it ends:

```
/deploy                          staging, from the branch Envoyer deploys
/deploy production               production, after you say yes
/deploy staging sha:abc123       a given commit
/deploy production branch:hotfix a given branch
```

It calls the environment's deploy hook, waits for Envoyer to list the new
deployment, follows it in the background and reports `finished`, `error`
or a timeout with the commit and message. Two optional steps run around
it:

- **Assets built in CI.** For projects whose client assets are built by a
  GitHub Actions workflow and cached on the server, it checks the tarball for
  the deployed commit is there before calling Envoyer, and waits for or
  starts the build when it is not.
- **Jira label.** With [Jira Worklog](https://github.com/jfeid/claude-jira)
  installed, a finished deploy syncs the `on-staging` label of the tickets
  with git.

This plugin is not made by or affiliated with Envoyer or Laravel.

## Install

At the prompt of a Claude Code terminal session:

```
/plugin install envoyer-deploy --marketplace jfeid/claude-deploy
```

Pick user scope to load it in every session. Then run `/deploy setup` in a
project, or set it up by hand:

1. **API token**, once per computer. Create a token in Envoyer (profile,
   API) that can read projects and deployments, and save it from a terminal
   of your own, not in the conversation:

   ```
   mkdir -p ~/.claude/deploy && chmod 700 ~/.claude/deploy
   read -rsp 'Envoyer API token: ' t && echo && (umask 077; jq -n --arg t "$t" '{api_token: $t}' > ~/.claude/deploy/config.json); unset t
   ```

   Or set `ENVOYER_API_TOKEN` in the environment.

2. **Project file**, once per project: `.claude/deploy.json` in the
   repository root, with the Envoyer project id and the deploy hook of each
   environment (Envoyer, project, Deployment Hooks: the part after
   `/deploy/`, or the whole URL):

   ```json
   {
     "projects": { "staging": 114567, "production": 125616 },
     "hooks": { "staging": "Abc123…", "production": "Def456…" }
   }
   ```

   **Add it to `.gitignore`.** A hook deploys without any login. `deploy.sh
   config` warns when the file is not ignored.

3. `deploy.sh check`: the project names, branches, hooks and last
   deployment of each environment.

## Use

```
/deploy [ENV] [sha:<commit>|branch:<name>]   deploy and wait for the result
/deploy status [ENV]                         the latest deployment of each environment
/deploy setup | help
```

`/deploy` hands what you typed to Claude, which loads the plugin's skill
(`envoyer-deploy`) and runs it. You can also ask in plain words ("deploy
this to staging", "what is on production?").

Environments are the keys of `projects`, so `qa` or `demo` work like
`staging`. Optional keys in `.claude/deploy.json`:

| Key | Effect |
|---|---|
| `default_environment` | the environment of a bare `/deploy`; default `staging` |
| `confirm` | environments that need a yes first; default `["production"]` |
| `jira_sync` | `false` turns the Jira label step off |
| `assets` | the CI asset check, below |

**What it does on Envoyer:** it calls the deploy hook of the environment you
named, once, and then only reads. It never retries a failed deployment, never
cancels one and changes no project settings.

### Assets built in CI

For a project where a GitHub Actions workflow builds the client assets, uploads
them to each server as `<cache_dir>/<hash>.tar.gz`, and an Envoyer deployment
hook installs the tarball (and fails without it):

```json
"assets": {
  "github_repo": "acme/shop",
  "github_account": "acme",
  "workflow": "build-assets.yml",
  "ssh": { "staging": "shop-staging", "production": "shop-prod" },
  "cache_dir": "envoyer/assets-cache",
  "hash_script": "deploy/asset-hash.sh"
}
```

| Key | Meaning |
|---|---|
| `github_repo` | the repository the workflow runs in |
| `github_account` | the `gh` account to use (`gh auth token -u`), when you have several; optional |
| `workflow` | the workflow file; it must accept `workflow_dispatch` inputs `ref` (commit) and `servers` (environment) |
| `ssh` | per environment, the ssh host or alias of the server |
| `cache_dir` | where the tarballs are, relative to the ssh user's home or absolute |
| `hash_script` | a script in the repository that prints the asset hash; default `deploy/asset-hash.sh` |

Before the trigger, Claude resolves the commit, runs the commit's hash script
on a copy of it (your working tree is not touched), checks the server over
ssh, and when the tarball is missing waits for the workflow run of that
commit or starts one. A failed build stops the deploy.

This needs the [GitHub CLI](https://cli.github.com/) signed in and ssh access
to the servers.

### The script

The plugin puts `deploy.sh` on the Bash tool's PATH:

```
deploy.sh config                 settings and files (never the token or hooks)
deploy.sh check [ENV]            token, projects, branches, hooks, last deployment
deploy.sh projects               Envoyer projects the token sees
deploy.sh latest ENV             the latest deployment
deploy.sh trigger ENV [sha:C|branch:B]
deploy.sh wait ENV ID [SECONDS]  until finished or error (default 5 minutes)
deploy.sh help                   every command
```

The skill lets Claude run these without a permission prompt, `trigger`
included: the skill runs only when you ask for a deploy, and asks before
the environments in `confirm`.

## Data

The plugin has no server, account, telemetry or update check. `deploy.sh`
connects only to Envoyer (`https://envoyer.io`, or `ENVOYER_URL`) with your
token, and, for the asset step, to your servers over ssh. See
[PRIVACY.md](PRIVACY.md).

The token and the hooks are never printed and never on a command line: the
script hands them to `curl` on standard input, so they are not in the
conversation or the process list. The skill tells Claude not to read either
file.

What Claude sees, and Claude Code sends to Anthropic as part of the
conversation: project names, branches, deployment ids, statuses, commit
hashes and messages, and for the asset step the workflow runs.

## What the mod does

The `/deploy` command comes from `hooks/register.ts`, a mod. It sends
nothing over the network and runs no programs. In detail:

- **What it registers:** the slash command `/deploy`. A plugin skill would
  show as `/envoyer-deploy:<name>`, so the skill is hidden from the `/`
  menu and the mod provides the plain name.
- **What it gives Claude:** for `/deploy <args>`, a prompt `deploy <args>`
  submitted as your own words, and a note only Claude reads, naming the
  skill to load and the arguments. Nothing else.
- **What it reads:** nothing: no files, environment variables or settings.
- **Hooks:** `session.start` registers the command; `command.run` answers
  `/deploy` only. No hook makes or changes a permission decision.

If you have your own `/deploy` command (`~/.claude/commands/deploy.md`),
remove or rename it, or the two clash.

## Requirements

- Claude Code 2.1.287 or later in the terminal (2.1.286 in the Desktop
  app's Code tab) for `/deploy`, which is a mod. On versions without mods,
  ask Claude in plain words and the skill runs the same way. claude.ai and
  Cowork do not install plugins with a `bin/` folder.
- An Envoyer account with an API token.
- bash (3.2 or later), `curl`, `jq` and git. On macOS: `brew install jq`.
  On Windows, [Git for Windows](https://gitforwindows.org/) plus jq.
- For the asset step: `gh` and `ssh`.

Sandbox: with Claude Code's sandbox turned on, allow `envoyer.io` for the
sandbox's network (`/sandbox`), or the first call is blocked. `gh` and `ssh`
need the system keyring and your ssh keys, so Claude runs them outside the
sandbox, which asks for your permission.

Used daily on Linux with Laravel projects on Envoyer. CI runs the script's
tests against a fake Envoyer API on Linux, macOS and Windows (Git Bash).

## Develop

```
claude --plugin-dir .              load it for one session
claude plugin validate --strict .
claude plugin test .               the mod's tests
bash tests/deploy-cli.sh           deploy.sh end to end against a fake Envoyer API
```

## Security and support

Questions and bugs: [GitHub issues](https://github.com/jfeid/claude-deploy/issues).
Security reports: see [SECURITY.md](SECURITY.md).

## License

MIT
