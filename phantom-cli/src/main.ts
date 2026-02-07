#!/usr/bin/env bun

// MARK: - Types

interface APIRequest {
  method: string;
  params?: Record<string, any>;
}

interface APIResponse {
  result?: any;
  error?: {
    code: string;
    message: string;
  };
}

interface Image {
  id: string;
  path: string;
  size: number;
}

interface VM {
  id: string;
  path: string;
  state: string;
}

// MARK: - TCP Client

async function sendRequest(request: APIRequest): Promise<APIResponse> {
  let buffer = "";
  let responseResolver: ((value: string) => void) | null = null;

  const responsePromise = new Promise<string>((resolve) => {
    responseResolver = resolve;
  });

  await Bun.connect({
    hostname: "localhost",
    port: 9090,
    socket: {
      data(_socket, data) {
        buffer += new TextDecoder().decode(data);

        // Check for newline delimiter
        const newlineIndex = buffer.indexOf("\n");
        if (newlineIndex !== -1) {
          const response = buffer.substring(0, newlineIndex);
          if (responseResolver) {
            responseResolver(response);
          }
          _socket.end();
        }
      },
      error(_socket, error) {
        console.error("Connection error:", error);
      },
      open(_socket) {
        // Send request with newline delimiter
        const requestJson = JSON.stringify(request) + "\n";
        _socket.write(requestJson);
      },
    },
  });

  const response = await responsePromise;
  return JSON.parse(response);
}

// MARK: - Commands

async function imageList() {
  const response = await sendRequest({ method: "images.list" });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  const images = response.result?.images as Image[] || [];

  if (images.length === 0) {
    console.log("No images available. Run 'phantom image pull' to download one.");
    return;
  }

  console.log("IMAGES");
  for (const image of images) {
    const sizeGB = (image.size / 1024 / 1024 / 1024).toFixed(2);
    console.log(`${image.id.padEnd(20)} ${sizeGB}GB`);
  }
}

async function imagePull() {
  console.log("Starting image download...");

  const response = await sendRequest({ method: "images.pull" });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(response.result?.message || "Download started");
  console.log("\nNote: Download happens in the background. Use 'phantom image list' to check when it's available.");
}

async function vmList() {
  const response = await sendRequest({ method: "vms.list" });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  const vms = response.result?.vms as VM[] || [];

  if (vms.length === 0) {
    console.log("No VMs. Run 'phantom run <IMAGE>' to create one.");
    return;
  }

  console.log("VM ID                STATE");
  for (const vm of vms) {
    console.log(`${vm.id.padEnd(20)} ${vm.state}`);
  }
}

async function vmRun(imageId: string) {
  if (!imageId) {
    console.error("Error: IMAGE required");
    console.error("Usage: phantom run <IMAGE>");
    process.exit(1);
  }

  console.log(`Creating VM from image ${imageId}...`);

  const response = await sendRequest({
    method: "vms.create",
    params: { imageId },
  });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(response.result?.message || "VM creation started");
  console.log("\nNote: VM creation happens in the background. Use 'phantom ps' to check status.");
}

async function vmStop(vmId: string) {
  if (!vmId) {
    console.error("Error: VM_ID required");
    console.error("Usage: phantom stop <VM_ID>");
    process.exit(1);
  }

  console.log(`Stopping VM ${vmId}...`);

  const response = await sendRequest({
    method: "vms.stop",
    params: { vmId },
  });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(`VM ${vmId} stopped`);
}

async function health() {
  const response = await sendRequest({ method: "health" });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(`Phantom daemon: ${response.result?.status || "unknown"}`);
  console.log(`Version: ${response.result?.version || "unknown"}`);
}

function showHelp() {
  console.log(`phantom - macOS VM manager CLI

Usage:
  phantom <command> [options]

Commands:
  image pull          Download macOS restore image from Apple
  image list          List available images
  ps                  Show running VMs
  run <IMAGE>         Create and start a new VM from image
  stop <VM_ID>        Stop a running VM
  health              Check daemon status

Examples:
  phantom image pull
  phantom image list
  phantom run 24C61
  phantom ps
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
    } else if (command === "ps") {
      await vmList();
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
