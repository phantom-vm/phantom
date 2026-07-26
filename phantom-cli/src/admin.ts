// Admin mode: the image-authoring commands (`ipsw`, `image build`,
// `image publish`, `vm boot-script`) are in every binary, but only listed and
// runnable when PHANTOM_ADMIN_MODE is set.
//
// This is decluttering, not access control. The commands ship in the one
// binary, this repo is public, and every one of them only asks the local
// daemon to do something the daemon would do for any caller anyway. The env
// var keeps `phantom help` about the commands a user of a published image
// actually needs; it is not a permission boundary and must never be relied on
// as one.
//
// (The CLI used to ship as two binaries from two entry points to keep this
// code out of the user build. That bought 16KB on a 63MB binary — the Bun
// runtime is the whole file — in exchange for two release assets and two
// build scripts, so the split was dropped.)

import type { Command } from "./command";

const ENV_VAR = "PHANTOM_ADMIN_MODE";

/// Set to anything meaningful. "0", "false" and an empty value read as off,
/// so `PHANTOM_ADMIN_MODE=0` doesn't surprise anyone by enabling it.
export function adminMode(): boolean {
  const value = process.env[ENV_VAR]?.trim().toLowerCase();
  return !!value && value !== "0" && value !== "false";
}

/// The handler an admin command gets outside admin mode. Routing to a real
/// error is the whole point — "unknown subcommand" would send an admin
/// hunting for a second binary that no longer exists.
export function refuse(name: string): () => never {
  return () => {
    console.error(`'phantom ${name}' is an image-authoring command, off by default.`);
    console.error(`Enable it with ${ENV_VAR}=1 — see docs/authoring-images.md.`);
    process.exit(1);
  };
}

/// `commands` in admin mode; outside it, the same commands hidden from help
/// and answering with `refuse`.
export function gate(prefix: string, commands: Record<string, Command>): Record<string, Command> {
  if (adminMode()) return commands;

  return Object.fromEntries(
    Object.entries(commands).map(([name, command]) => [
      name,
      {
        ...command,
        hidden: true,
        handler: undefined,
        multiArgHandler: refuse([prefix, name].filter(Boolean).join(" ")),
      },
    ])
  );
}
