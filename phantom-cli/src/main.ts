import { ipswList, ipswPull } from "./commands/ipsw";
import { vmList, vmStart, vmStop, vmDelete, vmExec, vmDisplay } from "./commands/vm";
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
  start: {
    handler: vmStart as (arg?: string) => Promise<void>,
  },
  stop: {
    handler: vmStop as (arg?: string) => Promise<void>,
  },
  exec: {
    multiArgHandler: vmExec,
  },
  display: {
    handler: vmDisplay as (arg?: string) => Promise<void>,
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
  ipsw pull                       Download macOS restore IPSW from Apple
  ipsw list                       List available IPSWs
  create --from-ipsw <IPSW_ID>    Create VM from IPSW
  create --from-vm <VM_ID>        Clone existing VM
  create --from-vm <VM_ID> --rm -- <cmd>
                                  Run ephemeral VM (clone, run, delete)
  create --from-vm <VM_ID> --rm --mount <path> -- <cmd>
                                  Ephemeral VM with host dir mounted at /Volumes/mount
  exec <VM_ID> -- <command>       Execute command in running VM
  display <VM_ID>                 Open VM display window
  list                            Show all VMs
  start <VM_ID>                   Start a stopped VM
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
