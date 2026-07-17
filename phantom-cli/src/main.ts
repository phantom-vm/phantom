import { ipswList, ipswPull } from "./commands/ipsw";
import { vmCreate, vmList, vmStart, vmStop, vmDelete, vmExec, vmDisplay, vmVnc, vmBootScript, vmScreenshot } from "./commands/vm";
import { imageList, imageDelete, imageSave, imagePush, imagePull } from "./commands/image";
import { health } from "./commands/health";
import { gitlabRunner } from "./commands/gitlab-runner";
import { route } from "./router";

// MARK: - Command Registry

const commands = {
  ipsw: {
    subcommands: {
      list: { handler: ipswList as (arg?: string) => Promise<void> },
      pull: { handler: ipswPull as (arg?: string) => Promise<void> },
    },
  },
  vm: {
    subcommands: {
      create: { multiArgHandler: vmCreate },
      list: { handler: vmList as (arg?: string) => Promise<void> },
      start: { handler: vmStart as (arg?: string) => Promise<void> },
      stop: { handler: vmStop as (arg?: string) => Promise<void> },
      exec: { multiArgHandler: vmExec },
      display: { handler: vmDisplay as (arg?: string) => Promise<void> },
      vnc: { multiArgHandler: vmVnc },
      "boot-script": { multiArgHandler: vmBootScript },
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
  console.log(`phantom - macOS VM manager CLI

Usage:
  phantom <command> [options]

Commands:
  ipsw list|pull                  Manage macOS IPSWs
  vm create|list|start|stop|exec|display|vnc|boot-script|screenshot|delete
                                  Manage VMs
  image list|delete|save|push|pull
                                  Manage images
  gitlab-runner prepare|run|cleanup
                                  GitLab custom executor integration
  health                          Check daemon status
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
