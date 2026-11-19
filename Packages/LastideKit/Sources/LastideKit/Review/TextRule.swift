import Foundation

/// The text rule of protocol section 7.4, check 7. The PC refuses a decision whose text breaks it with `invalidText`.
/// The phone runs the same rule before it builds a decision, so the person can fix the text at once. The PC's answer
/// still decides, because the two devices may know different Unicode versions.
public enum TextRule {
    /// Why a text breaks the rule.
    public enum Problem: Hashable, Sendable {
        /// Nothing but space separators (general category Zs).
        case empty
        /// More than 500 code points after NFC normalization.
        case tooLong
        /// A code point of general category Cc, Cf, Co, Cn, Zl or Zp, such as a line break or a bidi control.
        case hiddenCodePoint(Unicode.Scalar)
        /// An `@` that starts a word, which Claude Code reads as a file import.
        case fileImport
    }

    /// The first problem of `text`, in the order of section 7.4, or nil when the PC accepts the text.
    public static func problem(in text: String) -> Problem? {
        let scalars = Array(text.precomposedStringWithCanonicalMapping.unicodeScalars)
        if !scalars.contains(where: { !isSpace($0) }) { return .empty }
        if scalars.count > LastideProtocol.largestEditText { return .tooLong }
        if let hidden = scalars.first(where: isHidden) { return .hiddenCodePoint(hidden) }
        for (index, scalar) in scalars.enumerated() where scalar == "@" {
            let startsWord = index == 0 || isSpace(scalars[index - 1])
            let nameFollows = index + 1 < scalars.count && !isSpace(scalars[index + 1])
            if startsWord && nameFollows { return .fileImport }
        }
        return nil
    }

    /// A space separator, general category Zs.
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.generalCategory == .spaceSeparator }

    /// A code point the person cannot see: general category Cc, Cf, Co, Cn, Zl or Zp.
    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }
}
