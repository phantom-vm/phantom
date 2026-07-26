import Foundation
import Testing
@testable import Phantom

struct LogBufferTests {

    // MARK: - Bounding

    @Test func growsUntilTheTrimBlockIsExceeded() {
        var buffer = LogBuffer(maxLines: 10, trimBlock: 5)
        for i in 0..<15 { buffer.append(raw: "line \(i)") }
        // maxLines + trimBlock is the trigger, so 15 lines are still all present.
        #expect(buffer.lines.count == 15)
    }

    @Test func trimsBackToMaxLines() {
        var buffer = LogBuffer(maxLines: 10, trimBlock: 5)
        for i in 0..<16 { buffer.append(raw: "line \(i)") }
        #expect(buffer.lines.count == 10)
        // The oldest go; the newest are what a log reader wants.
        #expect(buffer.lines.first?.text == "line 6")
        #expect(buffer.lines.last?.text == "line 15")
    }

    @Test func staysBoundedOverManyAppends() {
        var buffer = LogBuffer(maxLines: 100, trimBlock: 10)
        for i in 0..<10_000 { buffer.append(raw: "line \(i)") }
        #expect(buffer.lines.count <= 110)
        #expect(buffer.lines.last?.text == "line 9999")
    }

    // MARK: - Identity

    /// The reason ids exist: `ForEach` identifying rows by array offset would treat
    /// every visible row as changed each time the buffer trims from the front.
    @Test func idsSurviveTrimming() {
        var buffer = LogBuffer(maxLines: 10, trimBlock: 5)
        for i in 0..<16 { buffer.append(raw: "line \(i)") }

        let idOfLine6 = buffer.lines.first!.id
        #expect(buffer.lines.first?.text == "line 6")

        for i in 16..<20 { buffer.append(raw: "line \(i)") }

        // "line 6" may or may not still be present, but any line that is present
        // kept the id it was given.
        if let stillThere = buffer.lines.first(where: { $0.text == "line 6" }) {
            #expect(stillThere.id == idOfLine6)
        }
        #expect(buffer.lines.map(\.id) == buffer.lines.map(\.id).sorted())
        #expect(Set(buffer.lines.map(\.id)).count == buffer.lines.count)
    }

    @Test func idsAreUniqueAndMonotonic() {
        var buffer = LogBuffer(maxLines: 1000, trimBlock: 100)
        for i in 0..<500 { buffer.append(raw: "line \(i)") }
        let ids = buffer.lines.map(\.id)
        #expect(ids == Array(0..<500))
    }

    // MARK: - Timestamping

    @Test func appendStampsTheLineAndRawDoesNot() {
        var buffer = LogBuffer()
        buffer.append("stamped")
        buffer.append(raw: "verbatim")

        #expect(buffer.lines[0].text.hasSuffix("stamped"))
        #expect(buffer.lines[0].text.first == "[")
        #expect(buffer.lines[1].text == "verbatim")
    }

    @Test func removeAllEmptiesTheBuffer() {
        var buffer = LogBuffer()
        buffer.append(raw: "a")
        buffer.removeAll()
        #expect(buffer.lines.isEmpty)
    }
}
