# CLI (Bun/TypeScript)

CLI that sends JSON-RPC requests to the daemon.

**One binary, one entry point** (`src/main.ts`, built by `bun run build`), with the image-authoring commands (`ipsw`, `image build`, `image build-base`, `image publish`, `vm boot-script`) gated behind the `PHANTOM_ADMIN_MODE` env var — `src/admin.ts`. Outside admin mode they are hidden from `phantom help` and answer with an error naming the variable rather than "unknown subcommand". This is presentation only: the commands are compiled into every binary, and the daemon API keeps all endpoints regardless of what the caller is showing in its help. It is explicitly **not** an access-control boundary. (Earlier versions shipped two binaries from two entry points, `main.ts` and `main-admin.ts`, so the user build's import graph excluded the authoring code; that saved 16KB on a 63MB binary — the Bun runtime dominates — and cost two release assets and two build scripts, so it was collapsed.) Each `commands/*.ts` module exports `Command` records — usage, description, option detail and the handler at one declaration site — that both the router and `phantom help` read directly (see `command.ts`, `cli.ts`).

**Entry point**: `phantom-cli/src/main.ts` — argument routing in `router.ts`, help rendering in `command.ts`/`cli.ts`, handlers under `commands/`.

**Help is three levels**, so the top of it stays an index rather than a specification:

| Level | Reached by | Shows |
|-------|-----------|-------|
| Index | `phantom` | One line per top-level command, no flags |
| Group | `phantom vm --help` | That command's subcommands and their argument forms |
| Command | `phantom vm deploy --help` | One subcommand: description, usage, options |

`--help` is the one form the CLI points at, so it is the only one its own text ever recommends. `phantom help [command [subcommand]]` reaches all three levels too and still routes, but it is not listed in the index and nothing suggests it — one way to ask is enough to teach.

A `Command` carries `details` — its option lines — beside `usage` and `description`, and a handler that rejects its arguments prints the same block through `usageError`. So the text a user reads after a mistake is the text they get from asking, and neither can drift from the other. Option detail therefore lives in the module that implements the command (`build.ts` and `publish.ts` export their own `Command`, which `image.ts` only aggregates), next to the parser that has to honour it.

`--help`/`-h` is intercepted in `cli.ts` before routing, so no handler ever sees it — several parse strictly and would reject it, which is how `image build --help` used to arrive as a usage error and exit 1. Only a help flag *before* a `--` separator counts: in `phantom vm exec <id> -- ls --help` the flag belongs to `ls`, in the guest.

**A usage error answers with help, not with a list of names.** The router only holds the registry — names and handlers — so `route()` takes a `HelpPrinter` from `cli.ts` and calls it wherever the arguments don't route: a bare group (`phantom vm`) prints the group, an unknown subcommand prints the group under an `Unknown vm subcommand: …` line, an unknown top-level command prints the index. Same text as `--help`, but on stderr and exiting 1 — asking for help succeeds, mistyping a command does not. It lives in the router rather than in a per-group handler, so a new group gets it by existing; a group that defines a real default handler (`image` lists, `ipsw` outside admin mode refuses) still runs that instead.

Admin gating runs through help unchanged: a gated command is absent from every index, and asking for help on one runs the same refusal that invoking it does, so it explains `PHANTOM_ADMIN_MODE` rather than answering "no help for that". A group whose commands are *all* gated (`ipsw`) refuses through `CommandGroup.hiddenHelp`.

**File Structure**:
```
phantom-cli/
└── src/
    ├── main.ts          # CLI entry point and command registry
    ├── router.ts        # Command routing
    ├── lib/api.ts       # TCP client (batch + streaming)
    ├── lib/recipe.ts    # the build recipe: parse, validate, resolve paths
    ├── lib/guest.ts     # what both builders share: exec in the guest, serve a file, wait out a save
    └── commands/
        ├── vm.ts            # create, list, start, stop, exec, display, vnc, boot-script, screenshot, delete
        ├── image.ts         # list, catalog, delete, save, push, pull, cancel
        ├── build.ts         # image build — recipe → layered image
        ├── build-base.ts    # image build-base — IPSW → base image
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

Not every command follows it: `image catalog`/`image pull` also read the public image catalog, `ipsw` reads the restore-image catalog, and `update` talks only to GitHub. Those raise `CliError` (`errors.ts`) so `cli.ts`'s catch-all doesn't report their failures as "failed to connect to phantom daemon", which is the right guess for everything else.

**Long operations are started, not awaited** — `image save`/`push`/`pull` return as soon as the daemon has taken the job, and the progress is read back with `image list`, which prints the running operation above the listing. `image cancel` is the exception that waits: it asks the daemon to stop, then polls `image.status` until the state turns over, because the answer a user wants is "it stopped", not "it has been asked to". An operation that finished first is reported as such rather than claimed as cancelled. A cancelled operation deletes what it wrote, so it is also the one finished state `image list` still prints — nothing in the listing below would otherwise show that anything happened.

The endpoints these commands call are documented in [api.md](api.md). The two
builders are the commands that are more than a wrapper around an endpoint — each
orchestrates a whole pipeline, described in
[images.md](images.md#automated-image-building). They are deliberately two
commands: `image build-base` turns an IPSW into a base image and is driven by
flags, while `image build` layers onto a base image and is driven by a recipe
file (`lib/recipe.ts`), because what goes on top of a base is what someone has to
read back a year later. Validation of a recipe happens before any daemon call —
`--dry-run` is that validation with the plan printed and nothing else done.

**Self-update**: `phantom update` looks up the latest release through the GitHub API, downloads that release's own `phantom-cli` asset by its versioned URL (never `releases/latest/download/`, which could move between the lookup and the fetch), writes it beside the running binary and `rename(2)`s it over `process.execPath` — atomic, and safe while executing, since this process keeps the inode it is already running. There is no signature check: release.yml signs and notarizes the daemon app but not this binary, so HTTPS to github.com is the whole trust anchor, exactly as much as the README's curl install it replaces. Two guards matter: a local version newer than the latest release is reported rather than silently downgraded (`--force` overrides), and the command refuses to run from a source checkout, where `process.execPath` is the *bun* binary and "updating" would overwrite the user's bun. The daemon has no equivalent — updating it is still manual.
