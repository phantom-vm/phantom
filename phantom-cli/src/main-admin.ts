// Admin entry point — includes the image-authoring commands (ipsw, image
// build, vm boot-script). Compiled by `bun run install-bin`.
//
// The user-facing build (`bun run build-user-bin`) compiles src/main.ts
// instead, which simply never imports commands/ipsw.ts or the adminCommands
// exports below — that's what keeps them (and their VNC/OCR/network-catalog
// code) out of that binary. A `--define`d runtime flag does NOT reliably
// achieve this: Bun's bundler folds a `const ADMIN = process.env.X === "1"`
// declaration to a literal, but does not then fold `ADMIN ? {...} : {}`
// itself once the surrounding module is more than a couple of functions —
// verified empirically. Plain unused-export elimination is reliable; don't
// replace this structure with a shared flag.
import { commands as ipswCommands } from "./commands/ipsw";
import { commands as vmCommands, adminCommands as vmAdminCommands } from "./commands/vm";
import { commands as imageCommands, adminCommands as imageAdminCommands } from "./commands/image";
import { command as healthCommand } from "./commands/health";
import { commands as gitlabRunnerHelp, gitlabRunner } from "./commands/gitlab-runner";
import { runCli } from "./cli";

const vmAll = { ...vmCommands, ...vmAdminCommands };
const imageAll = { ...imageCommands, ...imageAdminCommands };

runCli(() => ({
  routes: {
    ipsw: { subcommands: ipswCommands },
    vm: { subcommands: vmAll },
    image: { subcommands: imageAll, handler: imageAll.list!.handler },
    "gitlab-runner": { multiArgHandler: gitlabRunner },
    health: healthCommand,
  },
  groups: [
    { title: "VMs", prefix: "vm", commands: vmAll },
    { title: "Images", prefix: "image", commands: imageAll },
    { title: "GitLab CI", prefix: "gitlab-runner", commands: gitlabRunnerHelp },
    { title: "IPSW (image authoring)", prefix: "ipsw", commands: ipswCommands },
    {
      title: "Other",
      prefix: "",
      commands: { health: healthCommand, help: { usage: "", description: "Show this help" } },
    },
  ],
}));
