# UI

The daemon's SwiftUI window. Its view files are listed in
[core.md](core.md#daemon-swift-app); the state it reads is in
[core.md](core.md#state-management).

## GUI Layout

The window is a `NavigationSplitView` whose **shape depends on the selected
section**. Most sections list something, so they get the three columns OrbStack and
the Finder use; the Daemon log has nothing to list, so it gets two.

```
VMs / Images / Integration — three columns
┌──────────┬──────────────────┬──────────────────────────┐
│          │  Virtual  [⌵filter] [+]                     │
│ VMs      │  Machines        │                          │
│ Images   │ vm-a1b2c3d4      │ vm-a1b2c3d4              │
│          │   Running        │   Running                │
│ Daemon   │ vm-e5f6g7h8      │   [Stop] [Display]       │
│  Log     │   Stopped        │   Details: id, state,    │
│  Integr. │                  │   bundle path            │
│          │                  │   Run Command …          │
└──────────┴──────────────────┴──────────────────────────┘

Daemon › Log — two columns
┌──────────┬─────────────────────────────────────────────┐
│ VMs      │ Daemon Log                                  │
│ Images   │ [17:16:28] Found existing IPSW: 25D125.ipsw  │
│          │ [17:16:29] GitLab runner started (pid 83494) │
│ Daemon   │ [17:16:29] [gitlab-runner] Configuration …   │
│  Log   ◀ │                                             │
│  Integr. │                                             │
└──────────┴─────────────────────────────────────────────┘
```

`SidebarSection.hasListColumn` picks the branch. Two split views rather than one is
not a stylistic choice: **a three-column `NavigationSplitView` cannot hide its
middle column.** `navigationSplitViewColumnWidth(0)` and its `min/ideal/max` form
are both ignored for that column, and `NavigationSplitViewVisibility` only ever
hides columns from the leading side (`.doubleColumn` hides the sidebar,
`.detailOnly` hides the sidebar *and* the middle column) — there is no value for
"hide the middle one". Switching between a three-column and a two-column split view
is what gives the log the full width, and it costs nothing visible because the
sidebar and detail builders are shared between the branches.

No IPSW appears anywhere in this window. A user's starting point is a published
catalog image, pulled ready to boot; a macOS restore image is how those images get
*built*, which is an authoring concern — the CLI already gates `ipsw` behind
`PHANTOM_ADMIN_MODE` for the same reason, and the GUI used to contradict that by
keeping a restore-image panel in the sidebar of every install. The daemon still
serves `ipsw.list`/`pull`/`status` and `vm.create --ipswId`, because
`phantom image build-base` is how a base image is produced.

- **Sidebar** — two groups. The things the daemon manages (VMs, Images), each with
  a live count, then a **Daemon** group for the daemon itself: its Log and its
  Integrations.
- **List column** — the selected section's items, and only ever what this Mac
  has. Actions belonging to the collection rather than to one item live in the
  toolbar: VMs has a filter menu, Images its rescan/refresh, while both sections'
  **+** sits over the detail column (below). An image operation running anywhere
  — including one the CLI started, since `OCIImageManager.state` is shared —
  shows as a progress banner above the list, and a failed one stays there until
  dismissed. A *completed* one gets no banner: it put an image in the list below,
  which says it better than a line of text. While one runs with nothing in the
  list yet, the "No Images" empty state stands down — the banner already accounts
  for what is coming, and telling you to pull an image mid-pull reads as advice to
  start what is running.
- **Cancelling** — the running banner carries a **Cancel** beside the progress
  bar, the only place the operation is shown and so the only place it can be
  stopped. No confirmation: what it interrupts is named right beside it, and what
  it destroys is an image that does not exist yet. The button reads *Cancelling…*
  and dims until the daemon's state turns over, because a cancel lands only when
  the chunk in flight is done. The result is its own banner — dismissible, and
  visibly not a failure — since a cancelled operation deletes what it wrote and
  would otherwise leave no trace at all.
- **Acquiring vs. having** — a list column shows what you have; getting another
  one is an action, and actions are sheets behind the **+**. `CreateVMSheet`
  restores a VM from a local image, `PullImageSheet` lists the published catalog
  and pulls the chosen entry by `repository@digest`. The catalog is fetched when
  that sheet first opens, not at launch — a daemon nobody asks for an image on
  never reaches out to a registry. Images used to carry a **Local / Catalog**
  switch instead; two kinds of thing in one column is what forced the switch, and
  made a single selection binding serve two id spaces.
- **One sheet per intent, not per entry point** — an image's own *Create VM*
  opens `CreateVMSheet` with the image prefilled rather than creating a VM
  outright, so a VM started from an image gets the same naming and sizing as one
  started from the **+**. The sheet is presented by item, not by a flag, so each
  request rebuilds it and the prefill takes.
- **Turning one thing into another belongs to the thing** — a stopped VM's
  **Save as Image…** is in the VM's detail pane, not behind the Images **+**: it
  acts on *this* VM, while the **+** is for acquiring something this Mac does not
  have yet. It opens `SaveImageSheet`, which prefills the VM's id as the name,
  and when that name is already taken flips its button to **Replace** and says
  what replacing does (built alongside the old image, swapped in only on
  success). The button is dim while the VM runs — a running VM's disk would be
  captured mid-write — and while any image operation is in flight, since the
  manager takes one at a time. Starting a save selects the new name and switches
  to **Images**, where the banner and then the image itself are: the save runs
  for minutes, and a second progress bar in the VM pane would only be the same
  state drawn twice.
- **Where an image came from** — the image detail pane reads the build record the image carries and shows it under **Built**: when, by which CLI and daemon, on which macOS, from which base, which recipe (with its sha256) and the steps in order with their durations. An image saved by hand carries no record, and then the section is simply absent — a heading explaining that nothing is known would be noise in the common case. **Pulled From** stays what it was, beneath it: one says how the image was made, the other how this copy got here.
- **Detail pane** — everything about the selected item, including the lifecycle
  buttons and the exec console; `ContentUnavailableView` when nothing is
  selected. Both panes look their item up by id on every render, so one deleted
  over the API falls back to the placeholder instead of going stale.

Image listing walks the images directory, so `ContentView` caches the result and
reloads it when `OCIImageManager.state` enters or leaves a terminal state, not
on every progress tick.

### Filtering the VM list

The VMs column's toolbar holds a filter menu with one checkable item, **Show
Stopped VMs**, on by default and remembered in `@AppStorage`. Unchecking it hides
exactly the `.stopped` state: the transitional states (creating, installing,
restoring, stopping) and `.error` always show, because a VM that is mid-install or
broken is the one most worth seeing and hiding it is how it gets forgotten.

A row can leave the list without the selection changing — the filter is switched
off, or the selected VM stops — so `VMListView` clears the selection when the
selected id is no longer visible, rather than letting the detail pane outlive its
row.

### Daemon log

`VMManager.logs` is the daemon's whole log for the run, and **Daemon › Log** is the
page that shows it, filling the window right of the sidebar. It used to be a
collapsible pane under the columns behind a toolbar button, which made it a drawer
rather than a place and spent the toolbar slot the VM filter now uses.

The page is a log viewer, not a text dump: **one entry is exactly one row**, truncated
at the trailing edge, with the selected row's full text in a pane below and a draggable
split between them. A long entry — the runner's `key=value` output, a VM error carrying
a path — would otherwise reflow into three or four rows, and scanning a log means
reading down a column of aligned timestamps, not around paragraphs. Nothing selected
shows a "No Selection" placeholder.

The list is an `NSTableView` behind `NSViewRepresentable`
([LogTableView.swift](../../phantom/Views/LogTableView.swift)), not SwiftUI's `List`.
SwiftUI's `List` is already NSTableView-backed on macOS, so this is not a change of
engine — it is a change of control, and the control that matters is **update
granularity**. `List` hands its whole collection to the diffing machinery on every
change: to discover ten appended lines it compares every identifier in the buffer, which
is O(buffer) per append and a ceiling no constant-factor tuning moves.

Owning the table makes the update O(changed), and `LogBuffer` makes that easy. Its ids
are *contiguous* — `nextID` rises by one per append, trimming only removes from the head
— so the difference between two states is pure arithmetic on each one's first id and
count. `ChangePlan` computes it without scanning an array or comparing an element, and
the table applies it with `removeRows` and `insertRows`. There is also no "did the middle
change" question to get wrong, because the entry with a given id is immutable.

The rest of what owning the table buys:

- **No text measurement.** `rowHeight` is explicit and cells truncate rather than wrap,
  so laying out the list never depends on the length of a line. This is the main reason
  not wrapping is a performance decision and not only a legibility one.
- **Recycled cells.** One reused `NSTextField` per visible row instead of a SwiftUI view
  graph per row.
- **Follow the tail, unless the reader scrolled up.** Whether to stick to the bottom
  depends on where the reader currently is, which `defaultScrollAnchor(.bottom)` cannot
  express — and scrolling by hand on every count change is one scroll per appended line,
  exactly when the runner is noisiest.

Measured on a Debug build with 6000 lines buffered and 100 lines/second arriving into the
open page:

| Implementation | CPU (share of one core) |
|---|---|
| Wrapping `LazyVStack`, rows keyed by array offset, `scrollTo` per line | 40–56% |
| `LazyVStack`, stable ids, `defaultScrollAnchor(.bottom)` | 20–33% |
| `NSTableView`, one row per entry, `ChangePlan` updates | 15–20% |

Some of that remaining share is the harness generating the lines rather than the view
drawing them. The first row also had no cap on the buffer in production, so it degraded
further as the log grew.

`LogLinesView` is shared by the Daemon Log page and the GitLab Runner's Log tab, which
reads the runner's **own** log — see [core.md](core.md#logs) for why the runner stores
its output separately.

### Integration

**Daemon › Integration** lists the CI integrations the daemon can host:

- **GitLab Runner** — the one that works. Its two tabs render in the window toolbar
  rather than as a header band inside the pane: which view of the runner you are
  looking at is navigation, not content, and a band inside the pane would cost
  vertical space on every tab. They sit at the window's trailing edge, because
  `IntegrationListView` has no toolbar item to anchor them beside the divider (see
  Toolbar placement below) and there is no control that list of two fixed rows
  actually wants. **Info**
  shows state, whether it is registered, whether it is running, where it is registered
  and how many jobs it runs at once, the pinned version, whether the binary is present,
  and the config path, with start/stop and **Register…**/**Configure…**.
  **Log** is the runner's own output.

  `GitLabRunnerConfigSheet` is that form: GitLab URL, token, concurrency and the size of
  the VM each job gets, prefilled
  by reading `config.toml` back — `setup` keeps none of its arguments, and the file
  survives launches and hand edits, so the file is the only truth there is. One form
  covers two operations, because "what is this runner set to" is one question to the
  reader: concurrency is a global key the registration survives (`setConcurrent`
  patches the file and bounces the process, GitLab never hears about it), while a new
  URL or token can only be applied by registering again — so the button renames itself
  to **Re-register** and the sheet says what that discards *before* it happens.
  The **Job VM** sliders are `CreateVMSheet`'s, bounded the same way, and they are the one
  setting here that is phantom's rather than gitlab-runner's — so they go in `job-vm.json`
  beside the runner's config, never into `config.toml`, and applying them restarts
  nothing: they decide what the *next* job's VM is created with.

  Each consequence is stated before it happens, since nothing else on screen would show
  it: that applying discards a registration, that it restarts the runner and so
  interrupts a job in flight, or — for a size-only change — that it deliberately does
  neither. Concurrency tops out at two — every job is a VM and
  Virtualization.framework runs two macOS guests at a time — and a larger value already
  in the file is displayed as it is rather than clamped behind the user's back.
  The token is prefilled so that changing the URL doesn't cost one, masked behind a
  reveal toggle: it is plain text in `config.toml` either way, and hiding it in the
  GUI only keeps it off a screen someone is sharing. Registering writes the CLI's
  absolute path into the executor config, so the sheet needs one — the current
  `template.toml`'s if there is one, else `~/.local/bin`, `/usr/local/bin`,
  `/opt/homebrew/bin`; with no CLI installed it refuses rather than registering a
  runner whose every job would invoke a missing binary. Registration outlives the
  sheet (it downloads a binary and talks to GitLab), so the sheet dismisses and the
  state label behind it carries the progress and any failure.
- **GitHub Runner** — a placeholder saying it is coming. Listed so the section is
  honest about its scope instead of looking like it is only ever about GitLab.

### Toolbar placement

The **+** that opens the new-VM sheet sits over the detail column, at its leading
edge, and only in the VMs section; the sheet's own state lives in `ContentView`,
which already holds the image list and the selections it writes back to.

macOS has no toolbar placement that names "the detail column's leading edge" —
which column an item is declared on is the whole lever, and the arrangement is
load-bearing in a way worth writing down:

- An item on the **content** column sits at that column's trailing edge, just
  left of the split divider.
- An item on the **detail** column sits just right of the divider — but only
  while the content column has an item of its own. With the content column
  empty, it drifts to the window's trailing edge instead.

So the VM filter menu is doing two jobs: it is the list column's own control, and
it is what holds the **+** in place. The Images section works the same way, with
its refresh button playing the filter menu's part.

## GUI Reactivity

SwiftUI views automatically update when observable state changes:

```swift
@Bindable var vm: VMManager

var body: some View {
    // The list column re-renders as VM state changes, without any refresh call
    List(vm.listVMs(), id: \.id, selection: $selection) { info in
        VMRow(vmInfo: info, instance: vm.vmInstances[info.id])
    }
    .toolbar {
        Button("Create VM") {
            Task { await vm.createAndStartVM() }
        }
        .disabled(!canCreateVM)
    }
}
```

The detail pane reads the same observable state, so a VM started over the API
updates its buttons and status in the GUI with no notification path of its own.
