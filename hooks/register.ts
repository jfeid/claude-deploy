// The /deploy command of the envoyer-deploy plugin.
//
// The deploy itself is the plugin's skill, which needs a model turn. A plugin
// skill shows as /envoyer-deploy:<name>, so this mod registers a plain
// /deploy that hands the typed arguments to Claude with the skill to load.

import type { Register } from 'claude-code'

export const SKILL = 'envoyer-deploy:envoyer-deploy'

// The prompt the person sees under /deploy, and the note only Claude reads.
export function handOff(args: string): { prompt: string; note: string } {
  const a = args.trim()
  return {
    prompt: a ? `deploy ${a}` : 'deploy',
    note:
      `The person ran /deploy${a ? ` ${a}` : ''}. Load the ${SKILL} skill with the Skill tool, ` +
      `passing ${a ? `the arguments "${a}"` : 'no arguments'}, and follow it.`,
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    try {
      await $.command.register({
        name: 'deploy',
        description: 'Deploy with Envoyer and wait for the result',
        argumentHint: '[staging|production|ENV] [sha:<commit>|branch:<name>] | status | setup | help',
      })
    } catch (err) {
      // Another command already owns /deploy; the skill still answers plain requests.
      $.ui.log(`envoyer-deploy: /deploy not registered: ${String(err)}`)
    }
    return started
  })

  // The note is recorded after the command's row. The prompt starts Claude's
  // turn; the engine refuses a submit from inside this hook (it would wait on
  // the run this hook holds), so it goes from a timer once the hook returned.
  on('command.run', { command: 'deploy' }, async ($, e) => {
    const { prompt, note } = handOff(e.args)
    $.clock.after(1, () => {
      void $.prompt.submit({ text: prompt, asUser: true }).catch(err =>
        $.ui.log(`envoyer-deploy: /deploy could not start a turn: ${String(err)}`),
      )
    })
    return { context: [note] }
  }).catch(($, e, next) => next(e))
}
