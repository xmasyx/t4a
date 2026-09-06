//  TranscriptSearch.swift — finding text an alternate screen no longer owns.
//
//  An agent transcript is already structured as turns, so the search keeps
//  that structure instead of flattening the whole conversation into another
//  large allocation. Each field is matched independently and a hit keeps the
//  field-relative range the reader needs to reveal the same words.

import Foundation

public struct TranscriptHit: Sendable, Equatable {
    public enum Place: String, Sendable { case prompt, answer, step }
    public var turnID: Int
    public var place: Place
    public var stepID: String?
    public var range: NSRange
    public var excerpt: String
}

public enum TranscriptSearch {
    /// Colpi in ordine di turno e poi di posizione; `truncated` quando si è fermata al limite.
    public static func find(_ request: SearchRequest, in turns: [AgentTurn],
                            limit: Int = 5000) -> (hits: [TranscriptHit], truncated: Bool) {
        guard !request.text.isEmpty else { return ([], false) }
        guard limit > 0 else { return ([], true) }

        let pattern = request.mode == .regex
            ? request.text
            : NSRegularExpression.escapedPattern(for: request.text)
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: request.isCaseSensitive ? [] : [.caseInsensitive]) else {
            return ([], false)
        }

        var hits: [TranscriptHit] = []

        func appendMatches(in text: String, turnID: Int, place: TranscriptHit.Place,
                           stepID: String?) -> Bool {
            guard !text.isEmpty else { return false }
            let whole = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: whole) where match.range.length > 0 {
                guard let found = Range(match.range, in: text) else { continue }
                hits.append(TranscriptHit(
                    turnID: turnID, place: place, stepID: stepID,
                    range: match.range, excerpt: excerpt(in: text, around: found)))
                if hits.count >= limit { return true }
            }
            return false
        }

        for turn in turns {
            if appendMatches(in: turn.prompt, turnID: turn.id,
                             place: .prompt, stepID: nil) { return (hits, true) }
            if appendMatches(in: turn.answer, turnID: turn.id,
                             place: .answer, stepID: nil) { return (hits, true) }
            for step in turn.steps {
                let field = step.title + "\n" + step.detail
                if appendMatches(in: field, turnID: turn.id,
                                 place: .step, stepID: step.id) { return (hits, true) }
            }
        }
        return (hits, false)
    }

    /// About sixty human characters, because an excerpt is for recognition,
    /// not a second transcript. Newlines collapse here so every hit remains a
    /// single row in the find list.
    private static func excerpt(in text: String, around found: Range<String.Index>) -> String {
        let hitLength = text.distance(from: found.lowerBound, to: found.upperBound)
        let spare = max(0, 60 - hitLength)
        let beforeCount = spare / 2
        let afterCount = spare - beforeCount
        let start = text.index(found.lowerBound, offsetBy: -beforeCount,
                               limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(found.upperBound, offsetBy: afterCount,
                             limitedBy: text.endIndex) ?? text.endIndex
        let prefix = start == text.startIndex ? "" : "…"
        let suffix = end == text.endIndex ? "" : "…"
        let fragment = text[start..<end]
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return prefix + fragment + suffix
    }
}
