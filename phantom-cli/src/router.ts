type CommandHandler = (arg?: string) => Promise<void> | void;
type MultiArgCommandHandler = (...args: string[]) => Promise<void> | void;

interface CommandConfig {
  handler?: CommandHandler;
  multiArgHandler?: MultiArgCommandHandler;
  subcommands?: {
    [subcommand: string]: CommandConfig;
  };
}

interface CommandRegistry {
  [command: string]: CommandConfig;
}

/**
 * Prints the help for a command path — `[]` for the index, `["vm"]` for a
 * group — the way `phantom help <path>` would, but on stderr.
 *
 * The router knows names and handlers; the descriptions live in the help
 * metadata that only cli.ts holds. Passing the printer in is what lets a usage
 * error here show the same text as `--help` instead of a bare list of names.
 */
export type HelpPrinter = (path: string[]) => void;

export async function route(
  registry: CommandRegistry,
  args: string[],
  help: HelpPrinter,
  /// The commands already consumed, for the help a usage error prints.
  path: string[] = []
) {
  const command = args[0];
  const rest = args.slice(1);

  // Only reachable at the top level — a group invoked bare is handled below,
  // where the group's own help is the useful answer.
  if (!command) {
    console.error("No command provided");
    help(path);
    process.exit(1);
  }

  const config = registry[command];
  if (!config) {
    console.error(
      path.length > 0 ? `Unknown ${path.join(" ")} subcommand: ${command}` : `Unknown command: ${command}`
    );
    help(path);
    process.exit(1);
  }

  if (config.subcommands) {
    const here = [...path, command];
    if (!rest[0]) {
      // A group with a real default (`image` lists) runs it; otherwise naming
      // the group is a usage error, and the answer to it is the group's help.
      if (config.handler) {
        await config.handler(undefined);
        return;
      }
      help(here);
      process.exit(1);
    }
    await route(config.subcommands, rest, help, here);
    return;
  }

  // Handle direct commands with multiple args
  if (config.multiArgHandler) {
    await config.multiArgHandler(...rest);
    return;
  }

  // Handle direct commands with single arg
  if (config.handler) {
    await config.handler(rest[0]);
    return;
  }

  console.error(`Invalid command configuration for: ${command}`);
  process.exit(1);
}
