import { ipswList, ipswPull } from "./commands/ipsw";
import { vmList, vmStop, vmDelete, vmExec } from "./commands/vm";
import { vmCreate } from "./commands/create";
import { health } from "./commands/health";
import { route } from "./router";

// MARK: - Command Registry

const commands = {
  ipsw: {
    subcommands: {
      list: ipswList,
      pull: ipswPull,
    },
  },
  create: {
    multiArgHandler: vmCreate,
  },
  list: {
    handler: vmList as (arg?: string) => Promise<void>,
  },
  stop: {
    handler: vmStop as (arg?: string) => Promise<void>,
  },
  exec: {
    multiArgHandler: vmExec,
  },
  delete: {
    handler: vmDelete as (arg?: string) => Promise<void>,
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
  ipsw pull                       Download macOS restore image from Apple
  ipsw list                       List available IPSW images
  create --from-ipsw <IPSW_ID>    Create VM from IPSW image
  create --from-vm <VM_ID>        Clone existing VM
  create --from-vm <VM_ID> --rm -- <cmd>
                                  Run ephemeral VM (clone, run, delete)
  exec <VM_ID> -- <command>       Execute command in running VM
  list                            Show all VMs
  stop <VM_ID>                    Stop a running VM
  delete <VM_ID>                  Delete a VM
  health                          Check daemon status

Examples:
  phantom ipsw pull
  phantom ipsw list
  phantom create --from-ipsw 24C61
  phantom create --from-vm my-template-vm
  phantom create --from-vm my-template-vm --rm -- echo hello
  phantom exec vm-abc123 -- ls -la
  phantom list
  phantom stop vm-abc123
  phantom delete vm-abc123
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
