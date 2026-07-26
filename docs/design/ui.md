# UI

The daemon's SwiftUI window. Its view files are listed in
[core.md](core.md#daemon-swift-app); the state it reads is in
[core.md](core.md#state-management).

## GUI Layout

The window is a three-column `NavigationSplitView`, the shape OrbStack and the
Finder use:

```
┌──────────┬──────────────────┬──────────────────────────┐
│          │  Virtual   [log] │ [+]                      │
│ VMs      │  Machines        │                          │
│ Images   │ vm-a1b2c3d4      │ vm-a1b2c3d4              │
│          │   Running        │   Running                │
│          │ vm-e5f6g7h8      │   [Stop] [Display]       │
│          │   Stopped        │   Details: id, state,    │
│          │                  │   bundle path            │
│          │                  │   Run Command …          │
└──────────┴──────────────────┴──────────────────────────┘
│ Log (collapsible, toggled from the toolbar)            │
└────────────────────────────────────────────────────────┘
```

No IPSW appears anywhere in this window. A user's starting point is a published
catalog image, pulled ready to boot; a macOS restore image is how those images get
*built*, which is an authoring concern — the CLI already gates `ipsw` behind
`PHANTOM_ADMIN_MODE` for the same reason, and the GUI used to contradict that by
keeping a restore-image panel in the sidebar of every install. The daemon still
serves `ipsw.list`/`pull`/`status` and `vm.create --ipswId`, because
`phantom image build --ipsw` is how a base image is produced.

- **Sidebar** — the two things the daemon manages (`SidebarSection`), each with
  a live count, and nothing else.
- **List column** — the selected section's items. Actions that belong to the
  collection rather than to one item live in the toolbar: Images keeps its
  rescan/refresh here, while the VMs **+** sits over the detail column (below).
  An image
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
- **Log** — collapsed by default, below all three columns.

Image listing walks the images directory, so `ContentView` caches the result and
reloads it when `OCIImageManager.state` enters or leaves a terminal state, not
on every progress tick.

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

So the log toggle is declared on the content column, not merely to keep it out of
the way: without it there, the **+** would not stay put. In the Images section,
where the detail column has no item, the content column's own items (log toggle
and refresh) sit at the window's trailing edge — the log toggle is the one control
whose position depends on the section.

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
