import { ipswList, ipswPull } from "./commands/ipsw";
import { vmList, vmStart, vmStop, vmDelete, vmExec, vmDisplay } from "./commands/vm";
import { vmCreate } from "./commands/create";
import { health } from "./commands/health";
import { imageSave } from "./commands/save";
import { imagesList, imagesDelete } from "./commands/images";
import { imagePush } from "./commands/push";
import { imagePull } from "./commands/pull";
import { gitlabRunner } from "./commands/gitlab-runner";
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
  save: {
    multiArgHandler: imageSave,
  },
  push: {
    multiArgHandler: imagePush,
  },
  pull: {
    multiArgHandler: imagePull,
  },
  images: {
    subcommands: {
      list: imagesList,
      delete: imagesDelete,
    },
    handler: imagesList as (arg?: string) => Promise<void>,
  },
  "gitlab-runner": {
    multiArgHandler: gitlabRunner,
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
  create --from-image <IMAGE>     Create VM from a saved image
  create --from-vm <VM_ID> --rm -- <cmd>
                                  Run ephemeral VM (clone, run, delete)
  save <VM_ID> <IMAGE_NAME>       Save VM as a local OCI image
  images                          List saved images
  images delete <IMAGE_NAME>      Delete a saved image
  push <IMAGE> <REF>              Push image to OCI registry
  pull <REF> [--name <NAME>]      Pull image from OCI registry
  exec <VM_ID> -- <command>       Execute command in running VM
  display <VM_ID>                 Open VM display window
  list                            Show all VMs
  start <VM_ID>                   Start a stopped VM
  stop <VM_ID>                    Stop a running VM
  delete <VM_ID>                  Delete a VM
  health                          Check daemon status
  gitlab-runner prepare           GitLab custom executor: provision ephemeral VM
  gitlab-runner run <script> <stage>
                                  GitLab custom executor: run CI step in VM
  gitlab-runner cleanup           GitLab custom executor: delete ephemeral VM

Examples:
  phantom ipsw pull
  phantom create --from-ipsw 24C61
  phantom create --from-vm my-template-vm
  phantom save vm-abc123 macos-base
  phantom images
  phantom push macos-base ghcr.io/org/myvm:v1
  phantom pull ghcr.io/org/myvm:v1 --name pulled-image
  phantom create --from-image macos-base
  phantom exec vm-abc123 -- ls -la
  phantom list
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
