import Foundation
import Virtualization

/// Per-VM hardware sizing, stored as `vm.json` beside the disk image.
///
/// It has to be persisted rather than passed at create time: a VM is configured
/// again from scratch on every start, so without a record on disk a VM sized at
/// creation would silently revert to the defaults the next time it booted.
///
/// Bundles created before this file existed have none, and read back as
/// `.legacy` — the 4 CPUs / 16GB that used to be hardcoded, so nothing resizes
/// underneath an existing VM.
struct VMSettings: Codable, Equatable {
    var cpuCount: Int
    /// Bytes, matching `VZVirtualMachineConfiguration.memorySize`
    var memorySize: UInt64

    static let fileName = "vm.json"

    private static let gigabyte: UInt64 = 1024 * 1024 * 1024

    /// What a *new* VM gets when nobody says otherwise: half the host's cores
    /// and a quarter of its memory, leaving the majority of both to the Mac the
    /// VM is a guest on. `clamped()` because a small host can honour neither —
    /// on an 8GB machine the floor below is already more than the framework will
    /// hand out.
    ///
    /// Derived rather than constant: the sizes around it already are (the CPU
    /// ceiling is the host's core count), and one number cannot be right for both
    /// an 8-core laptop and a 24-core Studio.
    static var defaults: VMSettings {
        let host = ProcessInfo.processInfo
        return VMSettings(
            cpuCount: host.processorCount / 2,
            // A floor, not a fraction: a quarter of 16GB is 4GB, which is under
            // what Xcode and the simulators want.
            memorySize: max(host.physicalMemory / 4, 8 * gigabyte)
        ).clamped()
    }

    /// The size every VM was before `vm.json` existed. Only a bundle without one
    /// reads back as this — it is what those VMs have been booting with, and the
    /// host-derived default must not resize them years later.
    static let legacy = VMSettings(cpuCount: 4, memorySize: 16 * gigabyte)

    // MARK: - Allowed Ranges

    static var minimumCPUCount: Int { VZVirtualMachineConfiguration.minimumAllowedCPUCount }

    /// The framework's ceiling can exceed the cores the machine actually has
    /// (64 on a 12-core Mac), and a VM with more vCPUs than cores only
    /// contends with itself — so the host's core count is the real ceiling.
    static var maximumCPUCount: Int {
        min(VZVirtualMachineConfiguration.maximumAllowedCPUCount, ProcessInfo.processInfo.processorCount)
    }

    static var minimumMemorySize: UInt64 { VZVirtualMachineConfiguration.minimumAllowedMemorySize }

    static var maximumMemorySize: UInt64 { VZVirtualMachineConfiguration.maximumAllowedMemorySize }

    /// Bring values inside what the host allows. A VM asking for more than the
    /// machine has should boot smaller, not fail to start.
    func clamped() -> VMSettings {
        VMSettings(
            cpuCount: min(max(cpuCount, Self.minimumCPUCount), Self.maximumCPUCount),
            memorySize: min(max(memorySize, Self.minimumMemorySize), Self.maximumMemorySize)
        )
    }

    // MARK: - Persistence

    /// Read a bundle's settings. A missing or unreadable file means a bundle
    /// from before this file existed, which is `.legacy` — not `.defaults`,
    /// which would resize an existing VM the first time it booted under a
    /// host-derived default.
    static func load(from bundlePath: URL) -> VMSettings {
        let path = bundlePath.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: path),
              let settings = try? JSONDecoder().decode(VMSettings.self, from: data) else {
            return .legacy
        }
        return settings.clamped()
    }

    func write(to bundlePath: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: bundlePath.appendingPathComponent(Self.fileName))
    }
}

// MARK: - VM Names

/// A VM's id is also its directory name under `vms/`, so a name that travels
/// through the filesystem — or out of it — has to be ruled out before it
/// becomes a path.
enum VMName {
    static func isValid(_ name: String) -> Bool {
        !name.isEmpty
            && name.count <= 64
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func generate() -> String {
        "vm-\(UUID().uuidString.prefix(8).lowercased())"
    }
}
