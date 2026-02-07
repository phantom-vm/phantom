//

import SwiftUI
import Virtualization

@main
struct phantomApp: App {
    @State private var vm = VMManager()
    @State private var tcpServer: TCPServer?

    var body: some Scene {
        WindowGroup {
            ContentView(vm: vm)
                .task {
                    // Start TCP server on app launch
                    if tcpServer == nil {
                        tcpServer = TCPServer(vmManager: vm)
                        do {
                            try tcpServer?.start()
                        } catch {
                            print("Failed to start TCP server: \(error)")
                        }
                    }
                }
                .onDisappear {
                    // Stop server on app termination
                    tcpServer?.stop()
                }
        }
        Window("VM Display", id: "vm-display") {
            if let vmId = vm.displayedVMId,
               let instance = vm.vmInstances[vmId],
               case .running = instance.state,
               let virtualMachine = instance.virtualMachine {
                VMDisplayView(virtualMachine: virtualMachine)
                    .frame(minWidth: 1024, minHeight: 768)
            } else {
                Text("No VM selected or VM not running")
                    .frame(width: 400, height: 300)
            }
        }
    }
}
