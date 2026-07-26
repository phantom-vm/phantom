import SwiftUI

/// The daemon log, below the three columns and collapsed by default. It follows
/// the tail as lines arrive, the way it did when it owned half the window.
struct LogPane: View {
    let logs: [String]

    var body: some View {
        GroupBox("Log") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logs.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: logs.count) { _, _ in
                    if let last = logs.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .padding(10)
    }
}
