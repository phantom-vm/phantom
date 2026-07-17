import Foundation
import Virtualization

/// VNC server for a running VM, backed by Virtualization.framework's private
/// `_VZVNCServer` API (invoked via the ObjC runtime, no linker dependency).
///
/// Unlike guest-based screen sharing, this serves the framebuffer directly from
/// the host, so it works during macOS installation and Setup Assistant with no
/// software inside the guest — the foundation for automated image building.
@MainActor
final class VNCServer {

    enum VNCError: LocalizedError {
        case privateAPIUnavailable(String)
        case portTimeout

        var errorDescription: String? {
            switch self {
            case .privateAPIUnavailable(let detail):
                "VNC private API unavailable: \(detail)"
            case .portTimeout:
                "VNC server did not report a listening port in time"
            }
        }
    }

    let password: String
    private(set) var port: UInt16 = 0
    private let server: NSObject

    /// `vnc://:password@127.0.0.1:port`, available after `start()` succeeds
    var url: String? {
        port == 0 ? nil : "vnc://:\(password)@127.0.0.1:\(port)"
    }

    init(virtualMachine: VZVirtualMachine) throws {
        // Classic VNC auth only uses the first 8 characters of a password
        let password = Self.generatePassword(length: 8)
        self.password = password

        let secConfig = try Self.makeInstance(
            className: "_VZVNCAuthenticationSecurityConfiguration",
            initSelector: "initWithPassword:"
        ) { obj, sel, imp in
            typealias InitFn = @convention(c) (NSObject, Selector, NSString) -> NSObject?
            return unsafeBitCast(imp, to: InitFn.self)(obj, sel, password as NSString)
        }

        // Port 0 = let the system pick a free port
        server = try Self.makeInstance(
            className: "_VZVNCServer",
            initSelector: "initWithPort:queue:securityConfiguration:"
        ) { obj, sel, imp in
            typealias InitFn = @convention(c) (NSObject, Selector, UInt, AnyObject, AnyObject) -> NSObject?
            return unsafeBitCast(imp, to: InitFn.self)(obj, sel, 0, DispatchQueue.global(), secConfig)
        }

        server.setValue(virtualMachine, forKey: "virtualMachine")
    }

    /// Starts the server and waits until it reports a listening port.
    /// Returns the connection URL.
    func start(timeout: TimeInterval = 10) async throws -> String {
        _ = server.perform(NSSelectorFromString("start"))

        // Port stays 0 briefly after start() until the listener is up
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let reported = (server.value(forKey: "port") as? NSNumber)?.uint16Value, reported != 0 {
                port = reported
                return url!
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        stop()
        throw VNCError.portTimeout
    }

    func stop() {
        _ = server.perform(NSSelectorFromString("stop"))
        port = 0
    }

    // MARK: - Private API plumbing

    /// Allocates `className` and runs a custom init selector via its IMP.
    /// The caller's closure casts the IMP to the correct C function signature.
    private static func makeInstance(
        className: String,
        initSelector: String,
        invoke: (NSObject, Selector, IMP) -> NSObject?
    ) throws -> NSObject {
        guard let cls = NSClassFromString(className) as? NSObject.Type else {
            throw VNCError.privateAPIUnavailable("class \(className) not found")
        }
        let sel = NSSelectorFromString(initSelector)
        guard let method = class_getInstanceMethod(cls, sel) else {
            throw VNCError.privateAPIUnavailable("\(className) does not respond to \(initSelector)")
        }
        guard let alloc = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject else {
            throw VNCError.privateAPIUnavailable("failed to alloc \(className)")
        }
        guard let instance = invoke(alloc, sel, method_getImplementation(method)) else {
            throw VNCError.privateAPIUnavailable("\(initSelector) returned nil for \(className)")
        }
        return instance
    }

    private static func generatePassword(length: Int) -> String {
        let chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}
