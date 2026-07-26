import { renderGroup, type CommandGroup } from "./command";
import { route } from "./router";
import { CliError } from "./errors";
import { VERSION } from "./version";

export interface CliDefinition {
  routes: Record<string, any>;
  groups: CommandGroup[];
}

export async function runCli(build: () => CliDefinition) {
  const { routes, groups } = build();
  const commands = {
    ...routes,
    help: { handler: () => showHelp(groups) },
    "--help": { handler: () => showHelp(groups) },
    "-h": { handler: () => showHelp(groups) },
  };

  const args = process.argv.slice(2);
  if (args.length === 0) {
    showHelp(groups);
    process.exit(0);
  }

  if (args[0] === "--version" || args[0] === "-v" || args[0] === "version") {
    console.log(VERSION);
    process.exit(0);
  }

  try {
    await route(commands, args);
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

function showHelp(groups: CommandGroup[]) {
  const sections = groups.map(renderGroup).filter(Boolean).join("\n\n");

  console.log(`phantom ${VERSION} — the macOS VM orchestrator

Usage
  phantom <command> <subcommand> [options]

${sections}

Examples
  phantom image list
  phantom vm deploy --image tahoe-base && phantom vm list
  phantom vm exec <id> --user admin -- sw_vers
  phantom gitlab-runner setup --token glrt-xxx
`);
}
