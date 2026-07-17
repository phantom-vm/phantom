import Foundation

/// Parser for the boot-command keystroke DSL (same dialect as Packer /
/// tart's image templates):
///
///   `<wait>` `<wait30s>` `<wait1m>`        pauses
///   `<enter>` `<tab>` `<spacebar>` `<esc>` `<up>` `<f5>` ...  special keys
///   `<leftShiftOn>` / `<leftShiftOff>` ... modifier hold/release
///   `<click 'Some Text'>`                  OCR the screen, click matching text
///   anything else                          typed literally
nonisolated enum BootCommand {

    enum Step {
        case wait(TimeInterval)
        case keyDown(UInt32)
        case keyUp(UInt32)
        case keyPress(UInt32)
        case typeText(String)
        case click(String)
    }

    enum ParseError: LocalizedError {
        case unknownTag(String)
        case unterminatedTag(String)

        var errorDescription: String? {
            switch self {
            case .unknownTag(let tag): "Unknown boot command tag: <\(tag)>"
            case .unterminatedTag(let rest): "Unterminated '<' in boot command: \(rest)"
            }
        }
    }

    // X11 keysyms
    private static let specialKeys: [String: UInt32] = [
        "enter": 0xFF0D, "return": 0xFF0D,
        "tab": 0xFF09,
        "spacebar": 0x0020, "space": 0x0020,
        "esc": 0xFF1B,
        "bs": 0xFF08, "backspace": 0xFF08,
        "del": 0xFFFF, "delete": 0xFFFF,
        "up": 0xFF52, "down": 0xFF54, "left": 0xFF51, "right": 0xFF53,
        "home": 0xFF50, "end": 0xFF57,
        "pageup": 0xFF55, "pagedown": 0xFF56,
        "f1": 0xFFBE, "f2": 0xFFBF, "f3": 0xFFC0, "f4": 0xFFC1,
        "f5": 0xFFC2, "f6": 0xFFC3, "f7": 0xFFC4, "f8": 0xFFC5,
        "f9": 0xFFC6, "f10": 0xFFC7, "f11": 0xFFC8, "f12": 0xFFC9,
    ]

    // Modifiers usable as <nameOn> / <nameOff>.
    // Note: the guest interprets Alt as the Command key (e.g. <leftAltOn>q quits an app).
    private static let modifierKeys: [String: UInt32] = [
        "leftshift": 0xFFE1, "rightshift": 0xFFE2,
        "leftctrl": 0xFFE3, "rightctrl": 0xFFE4,
        "leftalt": 0xFFE9, "rightalt": 0xFFEA,
        "leftsuper": 0xFFEB, "rightsuper": 0xFFEC,
    ]

    /// Parses one boot command string into executable steps.
    static func parse(_ command: String) throws -> [Step] {
        var steps: [Step] = []
        var literal = ""
        var rest = Substring(command)

        func flushLiteral() {
            if !literal.isEmpty {
                steps.append(.typeText(literal))
                literal = ""
            }
        }

        while let char = rest.first {
            if char != "<" {
                literal.append(char)
                rest = rest.dropFirst()
                continue
            }

            guard let closeIndex = rest.firstIndex(of: ">") else {
                throw ParseError.unterminatedTag(String(rest))
            }
            let tag = String(rest[rest.index(after: rest.startIndex)..<closeIndex])
            rest = rest[rest.index(after: closeIndex)...]

            flushLiteral()
            steps.append(try parseTag(tag))
        }

        flushLiteral()
        return steps
    }

    /// Parses a list of boot commands (e.g. lines of a script).
    static func parse(commands: [String]) throws -> [[Step]] {
        try commands.map { try parse($0) }
    }

    private static func parseTag(_ tag: String) throws -> Step {
        let lower = tag.lowercased()

        // <wait>, <wait30s>, <wait1m>, <wait500ms>
        if lower.hasPrefix("wait") {
            let duration = String(lower.dropFirst("wait".count))
            if duration.isEmpty {
                return .wait(1)
            }
            if let seconds = parseDuration(duration) {
                return .wait(seconds)
            }
            throw ParseError.unknownTag(tag)
        }

        // <click 'Some Text'>
        if lower.hasPrefix("click ") {
            let argument = tag.dropFirst("click ".count).trimmingCharacters(in: .whitespaces)
            if argument.hasPrefix("'"), argument.hasSuffix("'"), argument.count >= 2 {
                return .click(String(argument.dropFirst().dropLast()))
            }
            throw ParseError.unknownTag(tag)
        }

        // Modifier hold/release: <leftShiftOn> / <leftShiftOff>
        if lower.hasSuffix("on"), let keysym = modifierKeys[String(lower.dropLast(2))] {
            return .keyDown(keysym)
        }
        if lower.hasSuffix("off"), let keysym = modifierKeys[String(lower.dropLast(3))] {
            return .keyUp(keysym)
        }

        if let keysym = specialKeys[lower] {
            return .keyPress(keysym)
        }

        throw ParseError.unknownTag(tag)
    }

    /// "30s" → 30, "2m" → 120, "500ms" → 0.5, "1m30s" → 90, bare "5" → 5
    private static func parseDuration(_ input: String) -> TimeInterval? {
        if let bare = Double(input) { return bare }

        var total: TimeInterval = 0
        var number = ""
        var unit = ""

        func flush() -> Bool {
            guard let value = Double(number) else { return false }
            switch unit {
            case "ms": total += value / 1000
            case "s": total += value
            case "m": total += value * 60
            case "h": total += value * 3600
            default: return false
            }
            number = ""
            unit = ""
            return true
        }

        for char in input {
            if char.isNumber || char == "." {
                if !unit.isEmpty {
                    guard flush() else { return nil }
                }
                number.append(char)
            } else {
                unit.append(char)
            }
        }
        guard flush(), total > 0 else { return nil }
        return total
    }

    /// Keysym for a literal character (printable ASCII and newline).
    /// Returns nil for characters that can't be typed directly.
    static func keysym(for character: Character) -> UInt32? {
        if character == "\n" { return 0xFF0D }
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1,
              scalar.value >= 0x20, scalar.value <= 0x7E else {
            return nil
        }
        return scalar.value
    }
}
