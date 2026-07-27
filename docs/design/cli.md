# CLI (Bun/TypeScript)

CLI that sends JSON-RPC requests to the daemon.

**One binary, one entry point** (`src/main.ts`, built by `bun run build`), with the image-authoring commands (`ipsw`, `image build`, `image publish`, `vm boot-script`) gated behind the `PHANTOM_ADMIN_MODE` env var — `src/admin.ts`. Outside admin mode they are hidden from `phantom help` and answer with an error naming the variable rather than "unknown subcommand". This is presentation only: the commands are compiled into every binary, and the daemon API keeps all endpoints regardless of what the caller is showing in its help. It is explicitly **not** an access-control boundary. (Earlier versions shipped two binaries from two entry points, `main.ts` and `main-admin.ts`, so the user build's import graph excluded the authoring code; that saved 16KB on a 63MB binary — the Bun runtime dominates — and cost two release assets and two build scripts, so it was collapsed.) Each `commands/*.ts` module exports `Command` records — usage, description, option detail and the handler at one declaration site — that both the router and `phantom help` read directly (see `command.ts`, `cli.ts`).

**Entry point**: `phantom-cli/src/main.ts` — argument routing in `router.ts`, help rendering in `command.ts`/`cli.ts`, handlers under `commands/`.

**Help is three levels**, so the top of it stays an index rather than a specification:

| Level | Reached by | Shows |
|-------|-----------|-------|
| Index | `phantom`, `phantom help` | One line per top-level command, no flags |
| Group | `phantom help vm`, `phantom vm --help` | That command's subcommands and their argument forms |
| Command | `phantom help vm deploy`, `phantom vm deploy --help` | One subcommand: description, usage, options |

A `Command` carries `details` — its option lines — beside `usage` and `description`, and a handler that rejects its arguments prints the same block through `usageError`. So the text a user reads after a mistake is the text they get from asking, and neither can drift from the other. Option detail therefore lives in the module that implements the command (`build.ts` and `publish.ts` export their own `Command`, which `image.ts` only aggregates), next to the parser that has to honour it.

`--help`/`-h` is intercepted in `cli.ts` before routing, so no handler ever sees it — several parse strictly and would reject it, which is how `image build --help` used to arrive as a usage error and exit 1. Only a help flag *before* a `--` separator counts: in `phantom vm exec <id> -- ls --help` the flag belongs to `ls`, in the guest.

Admin gating runs through help unchanged: a gated command is absent from every index, and asking for help on one runs the same refusal that invoking it does, so it explains `PHANTOM_ADMIN_MODE` rather than answering "no help for that". A group whose commands are *all* gated (`ipsw`) refuses through `CommandGroup.hiddenHelp`.

**File Structure**:
```
phantom-cli/
└── src/
    ├── main.ts          # CLI entry point and command registry
    ├── router.ts        # Command routing
    ├── lib/api.ts       # TCP client (batch + streaming)
    └── commands/
        ├── vm.ts            # create, list, start, stop, exec, display, vnc, boot-script, screenshot, delete
        ├── image.ts         # list, delete, save, push, pull
        ├── build.ts         # image build orchestrator
        ├── ipsw.ts          # IPSW management
        ├── gitlab-runner.ts # GitLab custom executor
        └── health.ts        # Daemon health check
```

**Command Flow**:
1. Parse command-line arguments
2. Construct JSON request: `{"method": "vm.list"}`
3. Connect to localhost:9090 via `Bun.connect()`
4. Send request with newline delimiter
5. Read response until newline
6. Parse JSON and display formatted output

Not every command follows it: `image list`/`image pull` also read the public image catalog, `ipsw` reads the restore-image catalog, and `update` talks only to GitHub. Those raise `CliError` (`errors.ts`) so `cli.ts`'s catch-all doesn't report their failures as "failed to connect to phantom daemon", which is the right guess for everything else.

The endpoints these commands call are documented in [api.md](api.md). `image build`
is the one command that is more than a wrapper around an endpoint — it orchestrates
a whole pipeline, described in [images.md](images.md#automated-image-building-image-build).

**Self-update**: `phantom update` looks up the latest release through the GitHub API, downloads that release's own `phantom-cli` asset by its versioned URL (never `releases/latest/download/`, which could move between the lookup and the fetch), writes it beside the running binary and `rename(2)`s it over `process.execPath` — atomic, and safe while executing, since this process keeps the inode it is already running. There is no signature check: release.yml signs and notarizes the daemon app but not this binary, so HTTPS to github.com is the whole trust anchor, exactly as much as the README's curl install it replaces. Two guards matter: a local version newer than the latest release is reported rather than silently downgraded (`--force` overrides), and the command refuses to run from a source checkout, where `process.execPath` is the *bun* binary and "updating" would overwrite the user's bun. The daemon has no equivalent — updating it is still manual.
