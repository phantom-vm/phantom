// A Command bundles a subcommand's implementation with its own usage/help
// text — one declaration site, so the two can't drift apart. commands/*.ts
// files export Record<string, Command>; main.ts only aggregates them into
// titled sections for `phantom help` and feeds the same records to the
// router for dispatch (Command is a structural superset of router.ts's
// CommandConfig, so no adapting is needed).
export interface Command {
  usage: string;
  description: string;
  /**
   * Option lines for `phantom help <command> <sub>`, rendered verbatim under
   * an "Options" heading. Declared here rather than inside the handler so the
   * handler's usage-error path can print the same block via `usageError` —
   * the detail is help text that happens to also appear on a failure, not the
   * other way round.
   */
  details?: string[];
  /**
   * Kept out of `phantom help` but still routable. Used for the admin
   * commands outside admin mode, so invoking one explains PHANTOM_ADMIN_MODE
   * instead of answering "unknown subcommand" — see admin.ts.
   */
  hidden?: boolean;
  handler?: (arg?: string) => Promise<void> | void;
  multiArgHandler?: (...args: string[]) => Promise<void> | void;
}

export interface CommandGroup {
  title: string;
  /** Top-level command prefix, e.g. "vm". Empty for a group of bare top-level commands. */
  prefix: string;
  /**
   * The group's one line in the top-level index. Prefixed groups only — a
   * group of bare commands is indexed command by command, each by its own
   * description.
   */
  summary?: string;
  /**
   * What `phantom help <prefix>` does when admin gating has hidden every
   * command in the group. Without it such a group is simply absent from help,
   * which would answer "unknown" where invoking it explains the env var.
   */
  hiddenHelp?: () => void;
  commands: Record<string, Command>;
}

/** Hidden commands still route; advertising them would undo the point. */
export function visible(commands: Record<string, Command>): [string, Command][] {
  return Object.entries(commands).filter(([, cmd]) => !cmd.hidden);
}

interface Row {
  left: string;
  description: string;
}

function table(rows: Row[]): string {
  const width = Math.max(...rows.map((r) => r.left.length)) + 2;
  return rows.map((r) => r.left.padEnd(width) + r.description).join("\n");
}

/**
 * The top level: one line per command a reader can type next, with no flags.
 * A prefixed group collapses to its prefix — its subcommands are a level down,
 * under `phantom help <prefix>`.
 */
export function renderIndex(groups: CommandGroup[]): string {
  const rows = groups.flatMap((group): Row[] => {
    const entries = visible(group.commands);
    // Also covers a group that is entirely hidden — the admin sections
    // outside admin mode.
    if (entries.length === 0) return [];
    if (!group.prefix) {
      return entries.map(([name, cmd]) => ({ left: "  " + name, description: cmd.description }));
    }
    return [{ left: "  " + group.prefix, description: group.summary ?? group.title }];
  });

  return table(rows);
}

/** One group's subcommands, with the argument form of each. */
export function renderGroup(group: CommandGroup): string {
  const entries = visible(group.commands);
  if (entries.length === 0) return "";

  const rows = entries.map(([name, cmd]) => ({
    left: "  " + [group.prefix, name, cmd.usage].filter((w) => w).join(" "),
    description: cmd.description,
  }));

  return [group.title, table(rows)].join("\n");
}

/** One subcommand in full: what it does, how to invoke it, what it takes. */
export function renderCommand(prefix: string, name: string, cmd: Command): string {
  const invocation = ["phantom", prefix, name, cmd.usage].filter((w) => w).join(" ");
  const lines = [cmd.description, "", "Usage", "  " + invocation];
  if (cmd.details?.length) {
    // A blank detail line is a paragraph break — indenting it would leave
    // trailing whitespace.
    lines.push("", "Options", ...cmd.details.map((line) => (line ? "  " + line : "")));
  }
  return lines.join("\n");
}

/**
 * What a handler prints when its arguments don't parse: the same block as
 * `phantom help <prefix> <name>`, on stderr. Callers exit non-zero themselves,
 * after whatever error line explains what was actually wrong.
 */
export function usageError(prefix: string, name: string, cmd: Command): void {
  console.error(renderCommand(prefix, name, cmd));
}
