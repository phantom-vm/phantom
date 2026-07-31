import { renderCommand, renderGroup, renderIndex, visible, type CommandGroup } from "./command";
import { route } from "./router";
import { CliError } from "./errors";
import { VERSION } from "./version";

export interface CliDefinition {
  routes: Record<string, any>;
  groups: CommandGroup[];
}

const HELP_FLAGS = new Set(["--help", "-h"]);

/**
 * The help path a `--help`/`-h` anywhere in the arguments is asking for, or
 * null if none was passed. Only flags *before* a `--` separator count:
 * `phantom vm exec <id> -- ls --help` is asking ls for help, not phantom.
 */
function helpFlagPath(args: string[]): string[] | null {
  const separator = args.indexOf("--");
  const scanned = separator === -1 ? args : args.slice(0, separator);
  if (!scanned.some((arg) => HELP_FLAGS.has(arg))) return null;
  return scanned.filter((arg) => !HELP_FLAGS.has(arg));
}

export async function runCli(build: () => CliDefinition) {
  const { routes, groups } = build();
  const commands = {
    ...routes,
    help: { multiArgHandler: (...path: string[]) => showHelp(groups, path) },
  };

  const args = process.argv.slice(2);
  if (args.length === 0) {
    showHelp(groups, []);
    process.exit(0);
  }

  if (args[0] === "--version" || args[0] === "-v" || args[0] === "version") {
    console.log(VERSION);
    process.exit(0);
  }

  // Intercepted here rather than in the router so no handler ever sees a help
  // flag: several parse their arguments strictly and would reject it, which is
  // how `image build --help` used to arrive as a usage error and exit 1.
  const helpPath = helpFlagPath(args);
  if (helpPath) {
    showHelp(groups, helpPath);
    process.exit(0);
  }

  try {
    // A usage error the router raises answers with the same help `--help`
    // gives, on stderr — see HelpPrinter.
    await route(commands, args, (path) => showHelp(groups, path, console.error));
  } catch (error) {
    // A CliError already knows what to say. Anything else is assumed to be a
    // failed connection, which is what almost every command here does first —
    // commands that don't talk to the daemon should raise CliError so this
    // doesn't misreport them.
    if (error instanceof CliError) {
      console.error(error.message);
      for (const line of error.detail) console.error(line);
      process.exit(1);
    }
    console.error("Failed to connect to phantom daemon");
    console.error("Make sure the phantom app is running");
    console.error("Error:", error);
    process.exit(1);
  }
}

/**
 * `path` is what to describe: nothing for the index, a top-level command for
 * its subcommands, a command and subcommand for that one in full.
 *
 * `log` is stdout when help was asked for and stderr when it is the answer to
 * a usage error — the text is the same either way, only the stream differs.
 */
function showHelp(groups: CommandGroup[], path: string[], log: (line: string) => void = console.log) {
  const [name, sub] = path;

  if (!name) {
    showIndex(groups, log);
    return;
  }

  // Bare top-level commands (health, update, help) live in the prefix-less
  // group, so look for a command of that name before a group of that name.
  const bare = groups
    .filter((group) => !group.prefix)
    .flatMap((group) => visible(group.commands).filter(([bareName]) => bareName === name));
  if (bare.length > 0 && !sub) {
    log(renderCommand("", name, bare[0]![1]));
    return;
  }

  const group = groups.find((candidate) => candidate.prefix === name);
  if (!group) {
    unknownHelpTarget(groups, path);
    return;
  }

  if (visible(group.commands).length === 0) {
    // Every command gated away — say what invoking it would say.
    if (group.hiddenHelp) group.hiddenHelp();
    else unknownHelpTarget(groups, path);
    return;
  }

  if (!sub) {
    log(renderGroup(group));
    log(`\nRun 'phantom ${name} <subcommand> --help' for one in full.`);
    return;
  }

  const command = group.commands[sub];
  if (!command) {
    unknownHelpTarget(groups, path);
    return;
  }

  // Asking for help on a gated command is asking to use it: let the refusing
  // handler explain PHANTOM_ADMIN_MODE rather than printing usage for
  // something that will not run.
  if (command.hidden) {
    const refuse = command.multiArgHandler ?? command.handler;
    if (refuse) {
      refuse();
      return;
    }
    unknownHelpTarget(groups, path);
    return;
  }

  log(renderCommand(name, sub, command));
}

function showIndex(groups: CommandGroup[], log: (line: string) => void) {
  log(`phantom ${VERSION} — the macOS VM orchestrator

Usage
  phantom <command> [subcommand] [options]

Commands
${renderIndex(groups)}

Run 'phantom <command> --help' for a command's subcommands, and again on a
subcommand for its flags.

Examples
  phantom image list
  phantom vm deploy --image tahoe-base && phantom vm list
  phantom vm exec <id> --user admin -- sw_vers
  phantom gitlab-runner setup --token glrt-xxx
`);
}

function unknownHelpTarget(groups: CommandGroup[], path: string[]) {
  console.error(`No help for '${path.join(" ")}'`);
  console.error("");
  console.error("Commands");
  console.error(renderIndex(groups));
  process.exit(1);
}
