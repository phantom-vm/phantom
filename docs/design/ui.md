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
`phantom image build --ipsw` is how a base image is produced.

- **Sidebar** — two groups. The things the daemon manages (VMs, Images), each with
  a live count, then a **Daemon** group for the daemon itself: its Log and its
  Integrations.
- **List column** — the selected section's items. Actions belonging to the
  collection rather than to one item live in the toolbar: VMs has a filter menu,
  Images its rescan/refresh, while the VMs **+** sits over the detail column
  (below). An image
  operation running anywhere — including one the CLI started, since
  `OCIImageManager.state` is shared — shows as a progress banner above the list.
  Images has a **Local / Catalog** switch: Catalog lists what the published
  catalog offers, marking what is already on disk, and its detail pane pulls the
  entry by `repository@digest`. The catalog is fetched on first visit to that
  tab, not at launch — a daemon nobody opens the tab on never reaches out to a
  registry.
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

`LogLinesView` renders the lines monospaced and follows the tail as they arrive. It
is shared with the GitLab Runner's Log tab, which is the same array filtered on the
`[gitlab-runner]` prefix — the runner's output is not stored separately,
`GitLabRunnerManager` writes it straight into the daemon log.

### Integration

**Daemon › Integration** lists the CI integrations the daemon can host:

- **GitLab Runner** — the one that works. Its detail pane has two tabs. **Info**
  shows state, whether it is registered, whether it is running, the pinned version,
  whether the binary is present, and the config path, with start/stop; registering
  needs a URL and a token, so it points at `phantom gitlab-runner setup` rather than
  reproducing that form. **Log** is the runner's own output.
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
it is what holds the **+** in place. In the Images section, where the detail column
has no item, the content column's refresh sits at the window's trailing edge
instead.

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
