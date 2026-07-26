import Foundation
import Testing
@testable import Phantom

/// `ChangePlan` is what lets the log table skip diffing: it turns "old state, new state"
/// into "this many trimmed from the head, this many appended at the tail" by exploiting
/// `LogBuffer`'s monotonic ids. If it is ever wrong the table's row count and the model
/// disagree, which AppKit turns into a crash rather than a glitch — hence the coverage.
struct ChangePlanTests {

    private func lines(ids: [Int]) -> [LogBuffer.Line] {
        ids.map { LogBuffer.Line(id: $0, text: "line \($0)") }
    }

    // MARK: - Appending

    @Test func pureAppend() {
        let plan = ChangePlan(from: lines(ids: [0, 1, 2]), to: lines(ids: [0, 1, 2, 3, 4]))
        #expect(plan?.trimmedFromHead == 0)
        #expect(plan?.appendedAtTail == 2)
    }

    @Test func firstFillFromEmpty() {
        let plan = ChangePlan(from: [], to: lines(ids: [0, 1, 2]))
        #expect(plan?.trimmedFromHead == 0)
        #expect(plan?.appendedAtTail == 3)
    }

    @Test func appendOfASingleLine() {
        let plan = ChangePlan(from: lines(ids: [7, 8]), to: lines(ids: [7, 8, 9]))
        #expect(plan?.trimmedFromHead == 0)
        #expect(plan?.appendedAtTail == 1)
    }

    // MARK: - Trimming

    @Test func pureTrim() {
        let plan = ChangePlan(from: lines(ids: [0, 1, 2, 3]), to: lines(ids: [2, 3]))
        #expect(plan?.trimmedFromHead == 2)
        #expect(plan?.appendedAtTail == 0)
    }

    /// The case LogBuffer actually produces: a trim and an append in one step.
    @Test func trimAndAppendTogether() {
        let plan = ChangePlan(from: lines(ids: [0, 1, 2, 3]), to: lines(ids: [2, 3, 4, 5]))
        #expect(plan?.trimmedFromHead == 2)
        #expect(plan?.appendedAtTail == 2)
    }

    @Test func trimPastEverythingOld() {
        // Every old id is gone: trimming 5 from a buffer that held 2 is impossible.
        let plan = ChangePlan(from: lines(ids: [0, 1]), to: lines(ids: [5, 6, 7]))
        #expect(plan == nil, "nothing of the old range survives — the table must reload")
    }

    /// The property that makes the arithmetic legitimate: ids are contiguous, so the
    /// plan never has to inspect an element. Guard it, because the fast path silently
    /// depends on it.
    @Test func logBufferIDsAreContiguous() {
        var buffer = LogBuffer(maxLines: 20, trimBlock: 5)
        for i in 0..<100 { buffer.append(raw: "line \(i)") }
        let ids = buffer.lines.map(\.id)
        #expect(ids == Array(ids[0]...ids[ids.count - 1]))
    }

    // MARK: - Shapes that must fall back to a reload

    @Test func clearedBufferHasNoPlan() {
        #expect(ChangePlan(from: lines(ids: [0, 1, 2]), to: []) == nil)
    }

    @Test func restartedBufferHasNoPlan() {
        // `removeAll` then refill: the new range starts below the old first id, so the
        // two states cannot be related by trimming and appending.
        #expect(ChangePlan(oldFirstID: 50, oldCount: 10, newFirstID: 0, newCount: 3) == nil)
    }

    @Test func shrinkingWithoutTrimmingHasNoPlan() {
        // The tail disappeared, which append-only never does.
        #expect(ChangePlan(from: lines(ids: [0, 1, 2, 3]), to: lines(ids: [0, 1])) == nil)
    }

    // MARK: - Consistency with LogBuffer

    /// The plan has to describe whatever LogBuffer really does, including across a trim,
    /// so drive it with the buffer rather than with hand-built arrays.
    @Test func planMatchesLogBufferAcrossTrimming() {
        var buffer = LogBuffer(maxLines: 10, trimBlock: 5)
        var previous = buffer.lines

        for i in 0..<200 {
            buffer.append(raw: "line \(i)")
            let current = buffer.lines

            if previous != current {
                let plan = ChangePlan(from: previous, to: current)
                #expect(plan != nil, "append \(i) produced a shape with no fast path")
                if let plan {
                    // Applying the plan to the old row count must land on the new one.
                    let projected = previous.count - plan.trimmedFromHead + plan.appendedAtTail
                    #expect(projected == current.count, "row count would desync at append \(i)")
                }
            }
            previous = current
        }
    }
}
