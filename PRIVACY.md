# Privacy

Envoyer Deploy (`envoyer-deploy`) is a Claude Code plugin by Giannis
Feidaros ([jfeid](https://github.com/jfeid)). This is what it handles.

## Where your data goes

The plugin has no server, account, telemetry, analytics or update check.
The developer receives nothing.

Its script (`deploy.sh`) connects to:

- **Envoyer** (`https://envoyer.io`, or `ENVOYER_URL`), with your API
  token: it reads your projects and deployments and calls the deploy hook
  of the environment you asked for.
- **Your servers**, over ssh, only for the optional asset step: it checks
  whether one file exists.

For the asset step Claude also runs the GitHub CLI (`gh`) under your own
GitHub login, to read and start workflow runs in the repository you
configured.

What Claude reads (project names, branches, deployment statuses, commit
hashes and messages, workflow runs) is part of your Claude Code
conversation, which Claude Code sends to Anthropic under the terms you use
Claude Code with.

## What it stores

Nothing of its own. It reads two files you write:

- `~/.claude/deploy/config.json` (or `DEPLOY_HOME`): your Envoyer API
  token. Alternatively the `ENVOYER_API_TOKEN` environment variable.
- `.claude/deploy.json` in each project: Envoyer project ids, deploy hooks
  and options.

The token and the hooks are passed to `curl` on standard input, never
printed and never on a command line, so they stay out of the conversation
and the process list.

## What it reads

The two files above; in the current git repository, the branches and
commits it deploys, and for the asset step a temporary copy of the
deployed commit, deleted afterwards; the environment variables listed in
the README. It does not read Claude Code's session files, transcripts,
history, memory, settings or credentials.

The `/deploy` command (a mod) reads nothing. It passes what you typed after
`/deploy` to Claude as a prompt, with a note naming the skill to load.

## Deleting

Remove `~/.claude/deploy/` and the projects' `.claude/deploy.json`.
Uninstalling the plugin leaves them in place. Revoke the token in Envoyer
when you no longer use it.

## Contact

Giannis Feidaros, [jfeid on GitHub](https://github.com/jfeid),
info@maxweb.gr. Questions can also go to the
[GitHub issues](https://github.com/jfeid/claude-deploy/issues).
