import SwiftUI

/// A log viewer: one entry per row, and the selected row's full text below.
///
/// Lines do not wrap. A long entry — the runner's `key=value` output, a VM error with
/// a path in it — would otherwise become three or four rows, so scanning the log means
/// reading around reflowed paragraphs instead of down a column of aligned timestamps.
/// Truncated rows are readable by selecting them, which is what the pane below is for.
///
/// The list itself is an `NSTableView` — see [LogTableView](LogTableView.swift) for why
/// SwiftUI's `List` is not enough here. The short version: `List` re-diffs the whole
/// buffer on every appended line, and the table can be told exactly what changed.
struct LogLinesView: View {
    let lines: [LogBuffer.Line]
    var emptyMessage = "Nothing logged yet."

    @State private var selection: LogBuffer.Line.ID?

    /// Looked up on every render rather than held, so a line the buffer trims away
    /// falls back to the placeholder instead of leaving stale text in the pane.
    private var selectedLine: LogBuffer.Line? {
        guard let selection else { return nil }
        return lines.first { $0.id == selection }
    }

    var body: some View {
        if lines.isEmpty {
            ContentUnavailableView(
                "No Log Output",
                systemImage: "text.alignleft",
                description: Text(emptyMessage)
            )
        } else {
            VSplitView {
                LogTableView(lines: lines, selection: $selection)
                    .frame(minHeight: 120, idealHeight: 400)

                // Capped, not merely given a small ideal: VSplitView does not honour the
                // ratio between two ideal heights, and without a ceiling this pane takes
                // half the window from the list it exists to support. Sized for the few
                // lines a wrapped log entry needs — drag it taller for a long one.
                detail
                    .frame(minHeight: 56, idealHeight: 84, maxHeight: 180)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedLine {
            ScrollView {
                Text(selectedLine.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        } else {
            Text("No Selection")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
