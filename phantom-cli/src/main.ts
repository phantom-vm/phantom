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
        list: { handler: ipswList as (arg?: string) => Promise<void> },
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
  const adminLines = ADMIN
    ? `  ipsw list|pull                  Manage macOS IPSWs
  image build <name>              Build a base image end-to-end (IPSW → agent → save)
  vm boot-script                  Drive Setup Assistant over VNC (image building)
`
    : "";
  console.log(`phantom - macOS VM manager CLI

Usage:
  phantom <command> [options]

Commands:
  vm deploy|list|start|stop|exec|display|vnc|screenshot|delete
                                  Manage VMs
  image list|delete|save|push|pull
                                  Manage images
  gitlab-runner setup|status|start|stop
                                  Managed GitLab CI runner (auto-downloads gitlab-runner)
  gitlab-runner prepare|run|cleanup
                                  GitLab custom executor hooks (called by the runner)
  health                          Check daemon status
${adminLines}`);
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
