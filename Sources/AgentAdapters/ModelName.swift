//  ModelName.swift — turning a model's file name into the two words a bar has
//  room for: `claude-opus-5` → `Opus 5` (ISC-104.3).
//
//  WHY IT LIVES HERE, and not with the bar that prints it (ISC-123). It used
//  to sit in `Sources/T4A/DashModel.swift`, and the table of families inside
//  it named every vendor in the world. That is precisely the thing ISC-31
//  forbids — the core is written against turns and states and knows no
//  vendor — and `Scripts/bench-agent.sh contract` had been red on that one
//  line since `21ac4b8`.
//
//  The families are not a list in this file either. Each adapter declares the
//  ones IT can produce, which is the property the rule is actually protecting:
//  a third vendor arrives with its own names, in its own file, and no line of
//  the core moves. There is deliberately no default for `modelFamilies`, so
//  the compiler asks the question of anyone writing a new adapter instead of
//  letting them inherit an empty answer in silence.

import Foundation
import TerminalCore

public enum ModelName {
    /// The family and its number, or the raw string when nothing is
    /// recognised — never a guess, and never a truncation, because half a
    /// model name is worse than a long one.
    public static func short(_ raw: String, families: [String]) -> String {
        guard !families.isEmpty else { return raw }
        let cleaned = raw.lowercased()
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // Longest first: a family whose name starts with another's would
        // otherwise be matched by the shorter one and lose its own tail.
        let alternatives = families.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let pattern = "(\(alternatives))-?(\\d+(?:[-.]\\d+)*)?"
        guard let match = cleaned.range(of: pattern, options: .regularExpression) else {
            return raw
        }
        let piece = String(cleaned[match])
        let bits = piece.split(separator: "-", maxSplits: 1).map(String.init)
        let family = bits[0].prefix(1).uppercased() + bits[0].dropFirst()
        guard bits.count > 1, !bits[1].isEmpty else { return family }
        return "\(family) \(bits[1].replacingOccurrences(of: "-", with: "."))"
    }
}

public extension AgentAdapter {
    /// The model as a bar can print it, shortened with this adapter's own
    /// family names.
    var shortModel: String { ModelName.short(model, families: Self.modelFamilies) }
}
