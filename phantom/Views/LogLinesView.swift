import SwiftUI

/// Monospaced log lines that stay pinned to the tail. Shared by the Daemon Log page
/// and the GitLab Runner's Log tab.
///
/// Three things here are about not stalling the window when the log is long — a
/// runner under load appends steadily, and the buffer holds thousands of lines:
///
/// - `ForEach` iterates the lines directly on their stable `id`. The obvious
///   `Array(lines.enumerated())` allocates a fresh array of tuples on every render,
///   and identifying rows by offset makes the whole list look changed each time
///   `LogBuffer` trims from the front.
/// - `LazyVStack` builds only the rows in view, so cost tracks the viewport rather
///   than the buffer.
/// - `defaultScrollAnchor(.bottom)` keeps the tail in view. Doing it by hand —
///   `ScrollViewReader` plus `scrollTo` on every count change — meant one scroll per
///   appended line, which is exactly when the runner is noisiest.
struct LogLinesView: View {
    let lines: [LogBuffer.Line]
    var emptyMessage = "Nothing logged yet."

    var body: some View {
        if lines.isEmpty {
            ContentUnavailableView(
                "No Log Output",
                systemImage: "text.alignleft",
                description: Text(emptyMessage)
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)
        }
    }
}

/// The Daemon > Log page: the daemon's own events for this run. The GitLab runner
/// keeps its own log, so its output does not bury these.
struct DaemonLogView: View {
    let lines: [LogBuffer.Line]

    var body: some View {
        LogLinesView(
            lines: lines,
            emptyMessage: "The daemon logs VM lifecycle and image operations here."
        )
        .navigationTitle("Daemon Log")
    }
}
