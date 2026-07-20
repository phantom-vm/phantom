// User entry point — regular users start from a published base image, so
// this deliberately never imports commands/ipsw.ts or the admin-only
// exports from commands/vm.ts and commands/image.ts. See the comment at the
// top of main-admin.ts for why that (plain unused-import elimination) is
// what actually keeps image-authoring code out of this build.
import { commands as vmCommands } from "./commands/vm";
import { commands as imageCommands } from "./commands/image";
import { command as healthCommand } from "./commands/health";
import { commands as gitlabRunnerHelp, gitlabRunner } from "./commands/gitlab-runner";
import { runCli } from "./cli";

runCli(() => ({
  routes: {
    vm: { subcommands: vmCommands },
    image: { subcommands: imageCommands, handler: imageCommands.list!.handler },
    "gitlab-runner": { multiArgHandler: gitlabRunner },
    health: healthCommand,
  },
  groups: [
    { title: "VMs", prefix: "vm", commands: vmCommands },
    { title: "Images", prefix: "image", commands: imageCommands },
    { title: "GitLab CI", prefix: "gitlab-runner", commands: gitlabRunnerHelp },
    {
      title: "Other",
      prefix: "",
      commands: { health: healthCommand, help: { usage: "", description: "Show this help" } },
    },
  ],
}));
