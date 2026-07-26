import Foundation
import Testing
@testable import Phantom

struct LineAssemblerTests {

    private static let esc = "\u{1B}"

    // MARK: - Line Reassembly

    @Test func splitsACompleteChunk() {
        var assembler = LineAssembler()
        #expect(assembler.take("one\ntwo\n") == ["one", "two"])
    }

    /// The defect this type exists for: a read boundary is not a line boundary.
    @Test func joinsALineSplitAcrossTwoReads() {
        var assembler = LineAssembler()
        #expect(assembler.take("Configuration lo") == [])
        #expect(assembler.take("aded\n") == ["Configuration loaded"])
    }

    @Test func holdsBackAnUnterminatedTail() {
        var assembler = LineAssembler()
        #expect(assembler.take("done\nhalf a li") == ["done"])
        #expect(assembler.take("ne\n") == ["half a line"])
    }

    @Test func aChunkWithNoNewlineYieldsNothingYet() {
        var assembler = LineAssembler()
        #expect(assembler.take("no newline here") == [])
        #expect(assembler.take(" and still none") == [])
        #expect(assembler.take("\n") == ["no newline here and still none"])
    }

    @Test func joinsALineSplitAcrossManyReads() {
        var assembler = LineAssembler()
        var out: [String] = []
        for character in "hello world\n" {
            out += assembler.take(String(character))
        }
        #expect(out == ["hello world"])
    }

    @Test func dropsBlankLines() {
        var assembler = LineAssembler()
        #expect(assembler.take("a\n\n\nb\n") == ["a", "b"])
    }

    // MARK: - Flush

    @Test func flushReturnsTheHeldFragment() {
        var assembler = LineAssembler()
        _ = assembler.take("trailing output with no newline")
        #expect(assembler.flush() == "trailing output with no newline")
        // And only once.
        #expect(assembler.flush() == nil)
    }

    @Test func flushIsNilWhenNothingIsHeld() {
        var assembler = LineAssembler()
        _ = assembler.take("complete\n")
        #expect(assembler.flush() == nil)
    }

    // MARK: - ANSI Stripping

    @Test func stripsColourCodes() {
        let line = "\(Self.esc)[0;33mWARNING: Running in user-mode.\(Self.esc)[0m"
        #expect(LineAssembler.clean(line) == "WARNING: Running in user-mode.")
    }

    /// The codes land mid-line, inside the `key=value` pairs gitlab-runner logs.
    @Test func stripsCodesFromTheMiddleOfALine() {
        let line = "See documentation \(Self.esc)[0;33mmax_builds\(Self.esc)[0m=1"
        #expect(LineAssembler.clean(line) == "See documentation max_builds=1")
    }

    @Test func stripsThroughTheAssembler() {
        var assembler = LineAssembler()
        let chunk = "\(Self.esc)[0;33mConfiguration loaded\(Self.esc)[0m\n"
        #expect(assembler.take(chunk) == ["Configuration loaded"])
    }

    @Test func leavesPlainTextAlone() {
        #expect(LineAssembler.clean("Runtime platform arch=arm64") == "Runtime platform arch=arm64")
    }

    @Test func aLineOfOnlyEscapeCodesIsDropped() {
        var assembler = LineAssembler()
        #expect(assembler.take("\(Self.esc)[0m\n") == [])
    }
}
