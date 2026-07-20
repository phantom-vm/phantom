import { ipswList, ipswPull } from "./commands/ipsw";
import { vmDeploy, vmList, vmStart, vmStop, vmDelete, vmExec, vmDisplay, vmVnc, vmBootScript, vmScreenshot } from "./commands/vm";
import { imageList, imageDelete, imageSave, imagePush, imagePull } from "./commands/image";
import { imageBuild } from "./commands/build";
import { health } from "./commands/health";
import { gitlabRunner } from "./commands/gitlab-runner";
import { route } from "./router";

// MARK: - Command Registry

// Image-authoring commands (IPSW download, Setup Assistant automation, image
// build) only exist in the admin build — `bun run install-bin` bakes
// PHANTOM_ADMIN in via --define, and the user build eliminates the code
// entirely. Regular users start from a published base image.
const ADMIN = process.env.PHANTOM_ADMIN === "1";

const commands = {
  ...(ADMIN && {
    ipsw: {
      subcommands: {
        list: { multiArgHandler: ipswList },
        pull: { handler: ipswPull as (arg?: string) => Promise<void> },
      },
    },
  }),
  vm: {
    subcommands: {
      deploy: { multiArgHandler: vmDeploy },
      list: { handler: vmList as (arg?: string) => Promise<void> },
      start: { handler: vmStart as (arg?: string) => Promise<void> },
      stop: { handler: vmStop as (arg?: string) => Promise<void> },
      exec: { multiArgHandler: vmExec },
      display: { handler: vmDisplay as (arg?: string) => Promise<void> },
      vnc: { multiArgHandler: vmVnc },
      ...(ADMIN && { "boot-script": { multiArgHandler: vmBootScript } }),
      screenshot: { multiArgHandler: vmScreenshot },
      delete: { handler: vmDelete as (arg?: string) => Promise<void> },
    },
  },
  image: {
    subcommands: {
      list: { handler: imageList as (arg?: string) => Promise<void> },
      delete: { handler: imageDelete as (arg?: string) => Promise<void> },
      save: { multiArgHandler: imageSave },
      push: { multiArgHandler: imagePush },
      pull: { multiArgHandler: imagePull },
      ...(ADMIN && { build: { multiArgHandler: imageBuild } }),
    },
    handler: imageList as (arg?: string) => Promise<void>,
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
  const adminSection = ADMIN
    ? `
Image authoring (admin build only)
  ipsw list [--include-betas]           List downloadable macOS restore images
  ipsw pull [version|build]             Download one (default: latest supported)
  image build <name> [options]          IPSW → agent install → provision → save, unattended
  vm boot-script <id> --file <script>   Drive Setup Assistant over VNC (used by image build)
`
    : "";

  console.log(`phantom — macOS VM manager CLI

Usage
  phantom <command> <subcommand> [options]

VMs
  vm deploy --image <name>              Boot a VM (also: --ipsw <id>, --template-vm <id>)
  vm list                               List VMs and their state
  vm start|stop <id>                    Start or stop a VM
  vm exec <id> [--user <name>] -- <cmd> Run a command inside a VM over vsock
  vm display <id>                       Open the VM's display window
  vm vnc <id> [--stop]                  Start/stop host-side VNC (vnc://...)
  vm screenshot <id> [--out <path>]     Capture the VM's framebuffer
  vm delete <id>                        Delete a VM

Images
  image list                            List local images (default with no subcommand)
  image save <vmId> <name>              Save a stopped VM as a local image
  image push <name> <registry:tag>      Push a local image to an OCI registry
  image pull <registry:tag> [--name]    Pull an image from an OCI registry
  image delete <name>                   Delete a local image

GitLab CI
  gitlab-runner setup --token <glrt-...>  Register + start a managed runner (one-time)
  gitlab-runner status|start|stop         Manage the runner process
  gitlab-runner prepare|run|cleanup       Custom executor hooks (called by gitlab-runner itself)
${adminSection}
Other
  health                                 Check daemon connectivity
  help                                   Show this help

Examples
  phantom image list
  phantom vm deploy --image tahoe-base && phantom vm list
  phantom vm exec <id> --user admin -- sw_vers
  phantom gitlab-runner setup --token glrt-xxx
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
