import { imageList, imagePull } from "./commands/image";
import { vmList, vmRun, vmStop } from "./commands/vm";
import { health } from "./commands/health";
import { route } from "./router";

// MARK: - Command Registry

const commands = {
  image: {
    subcommands: {
      list: imageList,
      pull: imagePull,
    },
  },
  list: {
    handler: vmList as (arg?: string) => Promise<void>,
  },
  run: {
    handler: vmRun as (arg?: string) => Promise<void>,
  },
  stop: {
    handler: vmStop as (arg?: string) => Promise<void>,
  },
  health: {
    handler: health as (arg?: string) => Promise<void>,
  },
  help: {
    handler: showHelp as (arg?: string) => void,
  },
  "--help": {
    handler: showHelp as (arg?: string) => void,
  },
  "-h": {
    handler: showHelp as (arg?: string) => void,
  },
};

// MARK: - Help

function showHelp() {
  console.log(`phantom - macOS VM manager CLI

Usage:
  phantom <command> [options]

Commands:
  image pull          Download macOS restore image from Apple
  image list          List available images
  list                Show running VMs
  run <IMAGE>         Create and start a new VM from image
  stop <VM_ID>        Stop a running VM
  health              Check daemon status

Examples:
  phantom image pull
  phantom image list
  phantom list
  phantom run 24C61
  phantom stop vm-abc123
`);
}

// MARK: - Main

async function main() {
  const args = process.argv.slice(2);

  if (args.length === 0) {
    showHelp();
    process.exit(0);
  }

  try {
    await route(commands, args);
  } catch (error) {
    console.error("Failed to connect to phantom daemon");
    console.error("Make sure the phantom app is running");
    console.error("Error:", error);
    process.exit(1);
  }
}

main().catch((error) => {
  console.error("Unhandled error:", error);
  process.exit(1);
});
