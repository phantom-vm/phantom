import Foundation
import Virtualization

/// Per-VM hardware sizing, stored as `vm.json` beside the disk image.
///
/// It has to be persisted rather than passed at create time: a VM is configured
/// again from scratch on every start, so without a record on disk a VM sized at
/// creation would silently revert to the defaults the next time it booted.
///
/// Bundles created before this file existed have none, and read back as
/// `.defaults` — the 4 CPUs / 16GB that used to be hardcoded, so nothing
/// resizes underneath an existing VM.
struct VMSettings: Codable, Equatable {
    var cpuCount: Int
    /// Bytes, matching `VZVirtualMachineConfiguration.memorySize`
    var memorySize: UInt64

    static let fileName = "vm.json"

    static let defaults = VMSettings(cpuCount: 4, memorySize: 16 * 1024 * 1024 * 1024)

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

    /// Read a bundle's settings, falling back to the defaults when the file is
    /// missing or unreadable.
    static func load(from bundlePath: URL) -> VMSettings {
        let path = bundlePath.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: path),
              let settings = try? JSONDecoder().decode(VMSettings.self, from: data) else {
            return .defaults
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
