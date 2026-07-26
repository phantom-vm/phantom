# UI

The daemon's SwiftUI window. Its view files are listed in
[core.md](core.md#daemon-swift-app); the state it reads is in
[core.md](core.md#state-management).

## GUI Layout

The window is a three-column `NavigationSplitView`, the shape OrbStack and the
Finder use:

```
┌──────────┬──────────────────┬──────────────────────────┐
│ VMs      │ vm-a1b2c3d4      │ vm-a1b2c3d4              │
│ Images   │   Running        │   Running                │
│          │ vm-e5f6g7h8      │   [Stop] [Display]       │
│          │   Stopped        │   Details: id, state,    │
│──────────│                  │   bundle path            │
│ Restore  │                  │   Run Command …          │
│ Image    │                  │                          │
└──────────┴──────────────────┴──────────────────────────┘
│ Log (collapsible, toggled from the toolbar)            │
└────────────────────────────────────────────────────────┘
```

- **Sidebar** — the two things the daemon manages (`SidebarSection`), each with
  a live count, over a footer for the IPSW restore image. The IPSW sits there
  rather than in Images because it is a host-level prerequisite for installing a
  VM from scratch, not one of the OCI images a VM is restored from.
- **List column** — the selected section's items, and the actions that belong to
  the collection rather than to one item (create a VM, rescan images). The VMs
  column's **+** opens a sheet for the VM's name, source image, CPU count and
  memory; with nothing to build from, that sheet offers the catalog and the
  restore image download instead of an unusable form. An image
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
