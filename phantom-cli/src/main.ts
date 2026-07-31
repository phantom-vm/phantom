// The one entry point. Every command is compiled in; the image-authoring
// ones are gated behind PHANTOM_ADMIN_MODE — see admin.ts for what that gate
// is and, more importantly, what it isn't.
import { commands as ipswCommands } from "./commands/ipsw";
import { commands as vmCommands, adminCommands as vmAdminCommands } from "./commands/vm";
import { commands as imageCommands, adminCommands as imageAdminCommands } from "./commands/image";
import { command as healthCommand } from "./commands/health";
import { command as updateCommand } from "./commands/update";
import { commands as gitlabRunnerCommands } from "./commands/gitlab-runner";
import { adminMode, gate, refuse } from "./admin";
import { runCli } from "./cli";

const admin = adminMode();

const vmAll = { ...vmCommands, ...gate("vm", vmAdminCommands) };
const imageAll = { ...imageCommands, ...gate("image", imageAdminCommands) };
const ipswAll = gate("ipsw", ipswCommands);

runCli(() => ({
  routes: {
    // Bare `phantom ipsw` would otherwise list the subcommands it is about to
    // refuse; outside admin mode it explains the env var like they do.
    ipsw: { subcommands: ipswAll, handler: admin ? undefined : refuse("ipsw") },
    vm: { subcommands: vmAll },
    image: { subcommands: imageAll, handler: imageAll.list!.handler },
    "gitlab-runner": { subcommands: gitlabRunnerCommands },
    health: healthCommand,
    update: updateCommand,
  },
  groups: [
    { title: "VMs", prefix: "vm", summary: "Boot, run commands in, and delete VMs", commands: vmAll },
    { title: "Images", prefix: "image", summary: "Local images and the registry they come from", commands: imageAll },
    {
      title: "GitLab CI",
      prefix: "gitlab-runner",
      summary: "The managed GitLab CI runner",
      commands: gitlabRunnerCommands,
    },
    {
      title: "IPSW (image authoring)",
      prefix: "ipsw",
      summary: "macOS restore images",
      // Outside admin mode every ipsw command is hidden, so `help ipsw` has
      // nothing to list — refuse the way `phantom ipsw` itself does.
      hiddenHelp: refuse("ipsw"),
      commands: ipswAll,
    },
    {
      title: "Other",
      prefix: "",
      commands: {
        health: healthCommand,
        update: updateCommand,
        help: { usage: "[command [subcommand]]", description: "Show help for a command" },
      },
    },
  ],
}));
