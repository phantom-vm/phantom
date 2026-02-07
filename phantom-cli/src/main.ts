import { imageList, imagePull } from "./commands/image";
import { vmList, vmRun, vmStop } from "./commands/vm";
import { health } from "./commands/health";

function showHelp() {
  console.log(`phantom - macOS VM manager CLI

Usage:
  phantom <command> [options]

Commands:
  image pull          Download macOS restore image from Apple
  image list          List available images
  vm list             Show running VMs
  run <IMAGE>         Create and start a new VM from image
  stop <VM_ID>        Stop a running VM
  health              Check daemon status

Examples:
  phantom image pull
  phantom image list
  phantom vm list
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

  const command = args[0];
  const subcommand = args[1];

  try {
    if (command === "image") {
      if (subcommand === "list") {
        await imageList();
      } else if (subcommand === "pull") {
        await imagePull();
      } else {
        console.error(`Unknown image subcommand: ${subcommand}`);
        console.error("Available: list, pull");
        process.exit(1);
      }
    } else if (command === "vm") {
      if (subcommand === "list") {
        await vmList();
      } else {
        console.error(`Unknown vm subcommand: ${subcommand}`);
        console.error("Available: list");
        process.exit(1);
      }
    } else if (command === "run") {
      await vmRun(subcommand || "");
    } else if (command === "stop") {
      await vmStop(subcommand || "");
    } else if (command === "health") {
      await health();
    } else if (command === "help" || command === "--help" || command === "-h") {
      showHelp();
    } else {
      console.error(`Unknown command: ${command}`);
      console.error("Run 'phantom help' for usage information");
      process.exit(1);
    }
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
