// A Command bundles a subcommand's implementation with its own usage/help
// text — one declaration site, so the two can't drift apart. commands/*.ts
// files export Record<string, Command>; main.ts only aggregates them into
// titled sections for `phantom help` and feeds the same records to the
// router for dispatch (Command is a structural superset of router.ts's
// CommandConfig, so no adapting is needed).
export interface Command {
  usage: string;
  description: string;
  handler?: (arg?: string) => Promise<void> | void;
  multiArgHandler?: (...args: string[]) => Promise<void> | void;
}

export interface CommandGroup {
  title: string;
  /** Top-level command prefix, e.g. "vm". Empty for a group of bare top-level commands. */
  prefix: string;
  commands: Record<string, Command>;
}

export function renderGroup(group: CommandGroup): string {
  const entries = Object.entries(group.commands);
  if (entries.length === 0) return "";

  const rows = entries.map(([name, cmd]) => ({
    left: "  " + [group.prefix, name, cmd.usage].filter((w) => w).join(" "),
    description: cmd.description,
  }));
  const width = Math.max(...rows.map((r) => r.left.length)) + 2;

  return [group.title, ...rows.map((r) => r.left.padEnd(width) + r.description)].join("\n");
}
