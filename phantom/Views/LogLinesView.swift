import SwiftUI

/// Monospaced log lines that follow the tail as they arrive. Shared by the Daemon
/// log page and the GitLab Runner's Log tab — both read `VMManager.logs`, the
/// runner's tab filtered to the lines it writes there.
struct LogLinesView: View {
    let lines: [String]
    var emptyMessage = "Nothing logged yet."

    var body: some View {
        if lines.isEmpty {
            ContentUnavailableView(
                "No Log Output",
                systemImage: "text.alignleft",
                description: Text(emptyMessage)
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: lines.count) { _, _ in
                    if let last = lines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
                .onAppear {
                    if let last = lines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }
}

/// The Daemon > Log page: every line the daemon has logged this run.
struct DaemonLogView: View {
    let logs: [String]

    var body: some View {
        LogLinesView(
            lines: logs,
            emptyMessage: "The daemon logs VM lifecycle, image operations and the managed runner here."
        )
        .navigationTitle("Daemon Log")
    }
}
