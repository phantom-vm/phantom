import Foundation

/// Turns arbitrary chunks of piped output into whole, clean log lines.
///
/// A child process is read with `availableData`, whose boundaries have nothing to do
/// with line boundaries: a line spanning two reads would be logged as two, and the
/// tail of a chunk is usually half a line. This holds that fragment until its newline
/// arrives.
///
/// It also strips ANSI escape sequences. gitlab-runner colours its output, and the
/// sequences land in the middle of the `key=value` pairs it logs, so stripping on the
/// way in keeps every reader — the GUI today, anything else later — from having to
/// cope with them.
struct LineAssembler {
    private var fragment = ""

    private static let ansiPattern = /\u{1B}\[[0-9;]*[a-zA-Z]/

    /// Complete lines contained in `chunk`, with any trailing partial line retained
    /// for the next call. Blank lines are dropped.
    mutating func take(_ chunk: String) -> [String] {
        let pending = fragment + chunk
        fragment = ""

        guard let lastNewline = pending.lastIndex(of: "\n") else {
            // No newline at all: the whole chunk is still an unfinished line.
            fragment = pending
            return []
        }

        fragment = String(pending[pending.index(after: lastNewline)...])

        return pending[..<lastNewline]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Self.clean(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Whatever is held back, for flushing when the stream ends without a newline.
    mutating func flush() -> String? {
        let remainder = Self.clean(fragment)
        fragment = ""
        return remainder.isEmpty ? nil : remainder
    }

    static func clean(_ line: String) -> String {
        line
            .replacing(ansiPattern, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
