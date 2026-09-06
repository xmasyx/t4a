//  ChatAttentionTests.swift — ISC-237's hierarchy and counter routing.

import Testing
@testable import AgentAdapters

@Test func tabSignHierarchyIsDecisionThenFinishedThenWorking() {
    #expect(ChatMarkKind.resolve(decisions: 2, hasFinished: true,
                                 finishedWasSeen: true,
                                 hasWorking: true) == .decision)
    #expect(ChatMarkKind.resolve(decisions: 0, hasFinished: true,
                                 finishedWasSeen: false,
                                 hasWorking: true) == .finished)
    #expect(ChatMarkKind.resolve(decisions: 0, hasFinished: false,
                                 finishedWasSeen: false,
                                 hasWorking: true) == .working)
    #expect(ChatMarkKind.resolve(decisions: 0, hasFinished: false,
                                 finishedWasSeen: false,
                                 hasWorking: false) == .none)
}

@Test func seenFinishedTurnHasNoFinishedMark() {
    #expect(ChatMarkKind.resolve(decisions: 0, hasFinished: true,
                                 finishedWasSeen: true,
                                 hasWorking: false) == .none)
    #expect(ChatMarkKind.resolve(decisions: 1, hasFinished: true,
                                 finishedWasSeen: true,
                                 hasWorking: false) == .decision)
}

@Test func onlyAVisitAfterTheFinishMarksItSeen() {
    var seen = FinishedTurnAttention.seenAfterUpdate(
        wasSeen: false, activity: .working,
        isNewFinish: false, isFocused: true)
    #expect(seen == false)

    seen = FinishedTurnAttention.seenAfterUpdate(
        wasSeen: seen, activity: .waiting,
        isNewFinish: true, isFocused: false)
    #expect(FinishedTurnAttention.needsAttention(activity: .waiting,
                                                 wasSeen: seen))

    seen = FinishedTurnAttention.seenAfterUpdate(
        wasSeen: seen, activity: .waiting,
        isNewFinish: false, isFocused: true)
    #expect(seen)
    #expect(!FinishedTurnAttention.needsAttention(activity: .waiting,
                                                  wasSeen: seen))
}

@Test func aNewFinishReactivatesAttention() {
    let duringWork = FinishedTurnAttention.seenAfterUpdate(
        wasSeen: true, activity: .working,
        isNewFinish: false, isFocused: false)
    #expect(duringWork)

    let newFinish = FinishedTurnAttention.seenAfterUpdate(
        wasSeen: duringWork, activity: .waiting,
        isNewFinish: true, isFocused: false)
    #expect(newFinish == false)
    #expect(FinishedTurnAttention.needsAttention(activity: .waiting,
                                                 wasSeen: newFinish))
}

@Test func aFinishArrivingInTheFocusedPaneIsBornSeen() {
    let seen = FinishedTurnAttention.seenAfterUpdate(
        wasSeen: false, activity: .waiting,
        isNewFinish: true, isFocused: true)
    #expect(seen)
    #expect(!FinishedTurnAttention.needsAttention(activity: .waiting,
                                                  wasSeen: seen))
}

@Test func aCoalescedNewFinishStillReactivatesAttention() {
    let seen = FinishedTurnAttention.seenAfterUpdate(
        wasSeen: true, activity: .waiting,
        isNewFinish: true, isFocused: false)
    #expect(seen == false)
}

@Test func waitingCounterRoutesZeroOneAndManyDifferently() {
    #expect(WaitingRoute.forCount(0) == .none)
    #expect(WaitingRoute.forCount(1) == .direct)
    #expect(WaitingRoute.forCount(2) == .menu)
    #expect(WaitingRoute.forCount(18) == .menu)
}

@Test func waitingAgeUsesHumanScaleWithoutDecimals() {
    #expect(WaitingAge.label(seconds: 0) == "now")
    #expect(WaitingAge.label(seconds: 17.9) == "17 s")
    #expect(WaitingAge.label(seconds: 125) == "2 min")
    #expect(WaitingAge.label(seconds: 7_201) == "2 h")
    #expect(WaitingAge.label(seconds: 172_900) == "2 d")
}
