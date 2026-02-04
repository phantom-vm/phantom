//

import SwiftUI
import Virtualization

@main
struct phantomApp: App {
    @State private var vm = VMManager()

    var body: some Scene {
        WindowGroup {
            ContentView(vm: vm)
        }
        Window("VM Display", id: "vm-display") {
            if let virtualMachine = vm.virtualMachine, vm.vmState == .running {
                VMDisplayView(virtualMachine: virtualMachine)
                    .frame(minWidth: 1024, minHeight: 768)
            } else {
                Text("No VM running")
                    .frame(width: 400, height: 300)
            }
        }
    }
}
