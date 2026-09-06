//  ScrollMeterSummary.swift — pure reduction for the external scroll meter.

import Foundation

/// Metrics derived from presentation timestamps expressed in milliseconds.
public struct ScrollMeterSummary: Equatable, Sendable {
    public let distinct: Int
    public let firstChange: Double?
    public let maxGap: Double?

    public init(distinct: Int, firstChange: Double?, maxGap: Double?) {
        self.distinct = distinct
        self.firstChange = firstChange
        self.maxGap = maxGap
    }

    /// Reduces dirty-frame presentation timestamps without depending on a
    /// capture API. Sorting here keeps an out-of-order callback from turning
    /// into a negative latency; equal PTS values still describe one frame.
    public static func reduce(timestamps: [Double], firstEventAt: Double) -> Self {
        let ordered = timestamps
            .filter { $0.isFinite && $0 >= firstEventAt }
            .sorted()
        var unique: [Double] = []
        unique.reserveCapacity(ordered.count)
        for timestamp in ordered where unique.last != timestamp {
            unique.append(timestamp)
        }
        let firstChange = unique.first.map { $0 - firstEventAt }
        let maxGap = zip(unique, unique.dropFirst()).map { $1 - $0 }.max()
        return Self(distinct: unique.count,
                    firstChange: firstChange,
                    maxGap: maxGap)
    }
}
