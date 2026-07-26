type CommandHandler = (arg?: string) => Promise<void> | void;
type MultiArgCommandHandler = (...args: string[]) => Promise<void> | void;

interface CommandConfig {
  /// See Command.hidden in command.ts — routable, but not advertised.
  hidden?: boolean;
  handler?: CommandHandler;
  multiArgHandler?: MultiArgCommandHandler;
  subcommands?: {
    [subcommand: string]: CommandConfig;
  };
}

interface CommandRegistry {
  [command: string]: CommandConfig;
}

/// What a "Available: ..." line offers — hidden commands still route, but
/// suggesting them would undo the point of hiding them.
function advertised(registry: CommandRegistry): string {
  return Object.entries(registry)
    .filter(([, config]) => !config.hidden)
    .map(([name]) => name)
    .join(", ");
}

export async function route(registry: CommandRegistry, args: string[]) {
  const command = args[0];
  const rest = args.slice(1);

  if (!command) {
    console.error("No command provided");
    console.error("Run 'phantom help' for usage information");
    process.exit(1);
  }

  const config = registry[command];
  if (!config) {
    console.error(`Unknown command: ${command}`);
    console.error("Run 'phantom help' for usage information");
    process.exit(1);
  }

  // Handle commands with subcommands
  if (config.subcommands) {
    const subcommand = rest[0];
    if (!subcommand) {
      if (config.handler) {
        await config.handler(undefined);
        return;
      }
      console.error(`${command} requires a subcommand`);
      console.error(`Available: ${advertised(config.subcommands)}`);
      process.exit(1);
    }
    const subConfig = config.subcommands[subcommand];
    if (!subConfig) {
      console.error(`Unknown ${command} subcommand: ${subcommand}`);
      console.error(`Available: ${advertised(config.subcommands)}`);
      process.exit(1);
    }
    await route({ [subcommand]: subConfig }, rest);
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
