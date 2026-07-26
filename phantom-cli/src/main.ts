// The one entry point. Every command is compiled in; the image-authoring
// ones are gated behind PHANTOM_ADMIN_MODE — see admin.ts for what that gate
// is and, more importantly, what it isn't.
import { commands as ipswCommands } from "./commands/ipsw";
import { commands as vmCommands, adminCommands as vmAdminCommands } from "./commands/vm";
import { commands as imageCommands, adminCommands as imageAdminCommands } from "./commands/image";
import { command as healthCommand } from "./commands/health";
import { commands as gitlabRunnerHelp, gitlabRunner } from "./commands/gitlab-runner";
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
    "gitlab-runner": { multiArgHandler: gitlabRunner },
    health: healthCommand,
  },
  groups: [
    { title: "VMs", prefix: "vm", commands: vmAll },
    { title: "Images", prefix: "image", commands: imageAll },
    { title: "GitLab CI", prefix: "gitlab-runner", commands: gitlabRunnerHelp },
    { title: "IPSW (image authoring)", prefix: "ipsw", commands: ipswAll },
    {
      title: "Other",
      prefix: "",
      commands: { health: healthCommand, help: { usage: "", description: "Show this help" } },
    },
  ],
}));
