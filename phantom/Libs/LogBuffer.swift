import Foundation

/// A bounded, append-only log whose lines keep a stable identity.
///
/// Both properties are load-bearing for the GUI:
///
/// - **Bounded.** A daemon runs for days and the GitLab runner streams continuously,
///   so an unbounded array grows for the lifetime of the process. Trimming happens in
///   blocks rather than one line at a time, so the runner's many appends do not each
///   turn into a shift of the whole array.
/// - **Stable ids.** The obvious `ForEach(Array(lines.enumerated()), id: \.offset)`
///   breaks the moment the buffer trims: dropping lines off the front shifts every
///   offset, so SwiftUI treats every visible row as changed and rebuilds the list.
///   A monotonic id survives trimming, and `ForEach` over `Line` needs no per-render
///   array allocation either.
struct LogBuffer {
    struct Line: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    private(set) var lines: [Line] = []

    private var nextID = 0
    private let maxLines: Int
    private let trimBlock: Int

    /// `DateFormatter.localizedString(from:dateStyle:timeStyle:)` is slow enough to
    /// matter on a path the runner hits for every line it prints, so the formatter is
    /// made once.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    init(maxLines: Int = 5000, trimBlock: Int = 500) {
        self.maxLines = maxLines
        self.trimBlock = trimBlock
    }

    /// Appends one line, stamped with the time it arrived.
    mutating func append(_ message: String) {
        append(raw: "[\(Self.timestampFormatter.string(from: Date()))] \(message)")
    }

    /// Appends a line exactly as given, for output that carries its own timestamp.
    mutating func append(raw text: String) {
        lines.append(Line(id: nextID, text: text))
        nextID += 1

        if lines.count > maxLines + trimBlock {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    mutating func removeAll() {
        lines.removeAll()
    }
}
