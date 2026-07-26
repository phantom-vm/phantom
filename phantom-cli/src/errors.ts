/**
 * A failure the user caused or can act on, with a message already written for
 * them. runCli prints `message` and nothing else.
 *
 * Everything else reaching runCli's catch is reported as a daemon connection
 * failure, which is right for the commands that only talk to the daemon and
 * wrong for the ones that don't — throw this from those.
 */
export class CliError extends Error {
  /** Extra lines printed under the message, e.g. what to do instead. */
  readonly detail: string[];

  constructor(message: string, ...detail: string[]) {
    super(message);
    this.name = "CliError";
    this.detail = detail;
  }
}
