//  ScrollMeterSummaryTests.swift — timestamps become the meter's verdict.

import AgentAdapters
import Testing

@Test func scrollMeterSummaryReducesDirtyFramePresentationTimes() {
    let summary = ScrollMeterSummary.reduce(
        timestamps: [1_040, 1_008, 1_024, 1_024, 990, .nan],
        firstEventAt: 1_000)

    #expect(summary.distinct == 3)
    #expect(summary.firstChange == 8)
    #expect(summary.maxGap == 16)
}

@Test func scrollMeterSummaryKeepsEmptyAndSingleFrameCasesHonest() {
    let empty = ScrollMeterSummary.reduce(timestamps: [10], firstEventAt: 20)
    #expect(empty.distinct == 0)
    #expect(empty.firstChange == nil)
    #expect(empty.maxGap == nil)

    let one = ScrollMeterSummary.reduce(timestamps: [25], firstEventAt: 20)
    #expect(one.distinct == 1)
    #expect(one.firstChange == 5)
    #expect(one.maxGap == nil)
}
