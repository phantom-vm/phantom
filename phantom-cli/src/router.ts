type CommandHandler = (arg?: string) => Promise<void> | void;
type MultiArgCommandHandler = (...args: string[]) => Promise<void> | void;

interface SubcommandConfig {
  [subcommand: string]: () => Promise<void>;
}

interface CommandConfig {
  handler?: CommandHandler;
  multiArgHandler?: MultiArgCommandHandler;
  subcommands?: SubcommandConfig;
}

interface CommandRegistry {
  [command: string]: CommandConfig;
}

export async function route(registry: CommandRegistry, args: string[]) {
  const command = args[0];
  const subcommand = args[1];

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
    if (!subcommand) {
      console.error(`${command} requires a subcommand`);
      console.error(`Available: ${Object.keys(config.subcommands).join(", ")}`);
      process.exit(1);
    }
    const handler = config.subcommands[subcommand];
    if (!handler) {
      console.error(`Unknown ${command} subcommand: ${subcommand}`);
      console.error(`Available: ${Object.keys(config.subcommands).join(", ")}`);
      process.exit(1);
    }
    await handler();
    return;
  }

  // Handle direct commands with multiple args
  if (config.multiArgHandler) {
    await config.multiArgHandler(...args.slice(1));
    return;
  }

  // Handle direct commands with single arg
  if (config.handler) {
    await config.handler(subcommand);
    return;
  }

  console.error(`Invalid command configuration for: ${command}`);
  process.exit(1);
}
