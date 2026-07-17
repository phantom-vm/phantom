import Foundation
import CommonCrypto
import CoreGraphics

/// Minimal RFB 3.8 (VNC) client used to drive a VM through its host-side VNC
/// server: keyboard/pointer injection and raw framebuffer capture.
///
/// Blocking socket I/O — use from a background task, never the main actor.
nonisolated final class RFBClient {

    enum RFBError: LocalizedError {
        case connectFailed(String)
        case protocolError(String)
        case authFailed
        case connectionClosed

        var errorDescription: String? {
            switch self {
            case .connectFailed(let detail): "VNC connect failed: \(detail)"
            case .protocolError(let detail): "VNC protocol error: \(detail)"
            case .authFailed: "VNC authentication failed"
            case .connectionClosed: "VNC connection closed"
            }
        }
    }

    private struct PixelFormat {
        var bitsPerPixel: Int
        var bigEndian: Bool
        var trueColour: Bool
        var maxR: UInt32, maxG: UInt32, maxB: UInt32
        var shiftR: UInt32, shiftG: UInt32, shiftB: UInt32
    }

    private let fd: Int32
    private var pixelFormat = PixelFormat(
        bitsPerPixel: 32, bigEndian: false, trueColour: true,
        maxR: 255, maxG: 255, maxB: 255, shiftR: 16, shiftG: 8, shiftB: 0
    )
    private(set) var width: Int = 0
    private(set) var height: Int = 0

    // MARK: - Connection

    init(host: String = "127.0.0.1", port: UInt16, password: String) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RFBError.connectFailed("socket() failed") }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            close(fd)
            throw RFBError.connectFailed("connect() to \(host):\(port) failed: errno \(errno)")
        }

        do {
            try handshake(password: password)
        } catch {
            close(fd)
            throw error
        }
    }

    deinit {
        close(fd)
    }

    private func handshake(password: String) throws {
        // ProtocolVersion
        let serverVersion = try readExactly(12)
        guard let versionString = String(data: serverVersion, encoding: .ascii),
              versionString.hasPrefix("RFB ") else {
            throw RFBError.protocolError("unexpected server greeting")
        }
        try writeAll(Data("RFB 003.008\n".utf8))

        // Security types
        let typeCount = try readUInt8()
        if typeCount == 0 {
            throw RFBError.protocolError("server rejected connection")
        }
        let types = try readExactly(Int(typeCount))
        guard types.contains(2) else {
            throw RFBError.protocolError("server does not offer VNC authentication")
        }
        try writeAll(Data([2]))

        // VNC authentication: DES-encrypt the 16-byte challenge
        let challenge = try readExactly(16)
        let response = Self.vncAuthResponse(challenge: challenge, password: password)
        try writeAll(response)

        let securityResult = try readUInt32()
        guard securityResult == 0 else {
            throw RFBError.authFailed
        }

        // ClientInit (shared = 1)
        try writeAll(Data([1]))

        // ServerInit — adopt the server's pixel format rather than sending
        // SetPixelFormat: _VZVNCServer's built-in backend traps on client
        // configurations it doesn't expect, so touch as little as possible.
        width = Int(try readUInt16())
        height = Int(try readUInt16())
        let format = try readExactly(16)
        pixelFormat = PixelFormat(
            bitsPerPixel: Int(format[0]),
            bigEndian: format[2] != 0,
            trueColour: format[3] != 0,
            maxR: UInt32(format[4]) << 8 | UInt32(format[5]),
            maxG: UInt32(format[6]) << 8 | UInt32(format[7]),
            maxB: UInt32(format[8]) << 8 | UInt32(format[9]),
            shiftR: UInt32(format[10]),
            shiftG: UInt32(format[11]),
            shiftB: UInt32(format[12])
        )
        let nameLength = Int(try readUInt32())
        _ = try readExactly(nameLength)

        guard pixelFormat.bitsPerPixel == 32, pixelFormat.trueColour else {
            throw RFBError.protocolError(
                "unsupported server pixel format: \(pixelFormat.bitsPerPixel)bpp, trueColour=\(pixelFormat.trueColour)")
        }

        // SetEncodings: Raw + DesktopSize pseudo-encoding — the same set the
        // tart Packer plugin advertises, which the server is known to accept
        var setEncodings = Data([2, 0]) // message type + padding
        setEncodings.append(uint16: 2)
        setEncodings.append(uint32: 0) // Raw
        setEncodings.append(uint32: UInt32(bitPattern: -223)) // DesktopSize
        try writeAll(setEncodings)
    }

    // MARK: - Input events

    /// X11 keysym, e.g. 0xFF0D for Return. Printable ASCII maps to itself.
    func sendKey(_ keysym: UInt32, down: Bool) throws {
        var msg = Data([4, down ? 1 : 0, 0, 0])
        msg.append(uint32: keysym)
        try writeAll(msg)
    }

    func pressKey(_ keysym: UInt32) throws {
        try sendKey(keysym, down: true)
        try sendKey(keysym, down: false)
    }

    /// buttonMask bit 0 = left button
    func sendPointer(x: Int, y: Int, buttonMask: UInt8) throws {
        var msg = Data([5, buttonMask])
        msg.append(uint16: UInt16(clamping: x))
        msg.append(uint16: UInt16(clamping: y))
        try writeAll(msg)
    }

    func clickAt(x: Int, y: Int) throws {
        try sendPointer(x: x, y: y, buttonMask: 0)
        try sendPointer(x: x, y: y, buttonMask: 1)
        usleep(100_000)
        try sendPointer(x: x, y: y, buttonMask: 0)
    }

    // MARK: - Framebuffer

    /// Requests a full (non-incremental) framebuffer update and returns it as a CGImage.
    func captureFramebuffer() throws -> CGImage {
        // A DesktopSize rect invalidates the frame; re-request at the new size
        while true {
            var request = Data([3, 0]) // type, incremental=0
            request.append(uint16: 0)
            request.append(uint16: 0)
            request.append(uint16: UInt16(width))
            request.append(uint16: UInt16(height))
            try writeAll(request)

            if let frame = try readFramebufferUpdate() {
                return try makeImage(from: frame)
            }
        }
    }

    /// Reads server messages until one FramebufferUpdate is fully processed.
    /// Returns the BGRA frame, or nil if the desktop was resized mid-update.
    private func readFramebufferUpdate() throws -> [UInt8]? {
        var frame = [UInt8](repeating: 0, count: width * height * 4)
        var resized = false

        while true {
            let messageType = try readUInt8()
            switch messageType {
            case 0: // FramebufferUpdate
                _ = try readUInt8() // padding
                let rectCount = Int(try readUInt16())
                for _ in 0..<rectCount {
                    let rx = Int(try readUInt16())
                    let ry = Int(try readUInt16())
                    let rw = Int(try readUInt16())
                    let rh = Int(try readUInt16())
                    let encoding = Int32(bitPattern: try readUInt32())
                    switch encoding {
                    case 0: // Raw
                        let pixels = try readExactly(rw * rh * 4)
                        guard !resized else { continue } // stale geometry
                        guard rx + rw <= width, ry + rh <= height else {
                            throw RFBError.protocolError("rectangle out of bounds")
                        }
                        copyPixels(pixels, into: &frame, x: rx, y: ry, w: rw, h: rh)
                    case -223: // DesktopSize pseudo-encoding — no pixel data
                        width = rw
                        height = rh
                        resized = true
                    default:
                        throw RFBError.protocolError("unexpected encoding \(encoding)")
                    }
                }
                return resized ? nil : frame
            case 1: // SetColourMapEntries
                _ = try readExactly(3)
                _ = try readUInt16() // first colour
                let colourCount = Int(try readUInt16())
                _ = try readExactly(colourCount * 6)
            case 2: // Bell
                break
            case 3: // ServerCutText
                _ = try readExactly(3)
                let textLength = Int(try readUInt32())
                _ = try readExactly(textLength)
            default:
                throw RFBError.protocolError("unknown server message \(messageType)")
            }
        }
    }

    /// Converts raw pixels from the server's format into BGRA in `frame`.
    private func copyPixels(_ pixels: Data, into frame: inout [UInt8], x: Int, y: Int, w: Int, h: Int) {
        let pf = pixelFormat
        pixels.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            for row in 0..<h {
                var srcOffset = row * w * 4
                var dstOffset = ((y + row) * width + x) * 4
                for _ in 0..<w {
                    let b0 = UInt32(src[srcOffset])
                    let b1 = UInt32(src[srcOffset + 1])
                    let b2 = UInt32(src[srcOffset + 2])
                    let b3 = UInt32(src[srcOffset + 3])
                    let value = pf.bigEndian
                        ? b0 << 24 | b1 << 16 | b2 << 8 | b3
                        : b3 << 24 | b2 << 16 | b1 << 8 | b0
                    var r = (value >> pf.shiftR) & pf.maxR
                    var g = (value >> pf.shiftG) & pf.maxG
                    var b = (value >> pf.shiftB) & pf.maxB
                    if pf.maxR != 255 { r = r * 255 / max(pf.maxR, 1) }
                    if pf.maxG != 255 { g = g * 255 / max(pf.maxG, 1) }
                    if pf.maxB != 255 { b = b * 255 / max(pf.maxB, 1) }
                    frame[dstOffset] = UInt8(b)
                    frame[dstOffset + 1] = UInt8(g)
                    frame[dstOffset + 2] = UInt8(r)
                    frame[dstOffset + 3] = 255
                    srcOffset += 4
                    dstOffset += 4
                }
            }
        }
    }

    private func makeImage(from bgra: [UInt8]) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
            .union(.byteOrder32Little)
        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let image = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: bitmapInfo,
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw RFBError.protocolError("failed to build framebuffer image")
        }
        return image
    }

    // MARK: - VNC DES auth

    /// VNC auth: DES-ECB encrypt the challenge, key = password bytes with
    /// reversed bit order (RFB quirk), null-padded to 8 bytes.
    private static func vncAuthResponse(challenge: Data, password: String) -> Data {
        var key = [UInt8](repeating: 0, count: 8)
        for (i, byte) in password.utf8.prefix(8).enumerated() {
            var value = byte
            var reversed: UInt8 = 0
            for _ in 0..<8 {
                reversed = (reversed << 1) | (value & 1)
                value >>= 1
            }
            key[i] = reversed
        }

        var output = [UInt8](repeating: 0, count: 16)
        var outputLength = 0
        let challengeBytes = [UInt8](challenge)
        CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmDES),
            CCOptions(kCCOptionECBMode),
            key, kCCKeySizeDES,
            nil,
            challengeBytes, challengeBytes.count,
            &output, output.count,
            &outputLength
        )
        return Data(output)
    }

    // MARK: - Socket I/O

    private func readExactly(_ count: Int) throws -> Data {
        var buffer = Data(capacity: count)
        var chunk = [UInt8](repeating: 0, count: min(count, 65536))
        while buffer.count < count {
            let wanted = min(count - buffer.count, chunk.count)
            let n = read(fd, &chunk, wanted)
            guard n > 0 else { throw RFBError.connectionClosed }
            buffer.append(contentsOf: chunk[0..<n])
        }
        return buffer
    }

    private func readUInt8() throws -> UInt8 {
        try readExactly(1)[0]
    }

    private func readUInt16() throws -> UInt16 {
        let data = try readExactly(2)
        return UInt16(data[0]) << 8 | UInt16(data[1])
    }

    private func readUInt32() throws -> UInt32 {
        let data = try readExactly(4)
        return UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3])
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < ptr.count {
                let n = write(fd, ptr.baseAddress! + offset, ptr.count - offset)
                guard n > 0 else { throw RFBError.connectionClosed }
                offset += n
            }
        }
    }
}

// MARK: - Big-endian Data helpers

private extension Data {
    nonisolated mutating func append(uint16 value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    nonisolated mutating func append(uint32 value: UInt32) {
        append(UInt8(value >> 24))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
