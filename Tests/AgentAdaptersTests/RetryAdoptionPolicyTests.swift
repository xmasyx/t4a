//  RetryAdoptionPolicyTests.swift — the lifecycle of the only idle-pane timer.

import Testing
@testable import AgentAdapters

@Test func retryStartsForAnAttachedAgentWithoutAProcess() {
    #expect(RetryAdoptionPolicy.shouldRun(
        sessionIsAlive: true, isAttached: true, hasProcess: false))
}

@Test func retryStopsAsSoonAsTheProcessArrives() {
    #expect(!RetryAdoptionPolicy.shouldRun(
        sessionIsAlive: true, isAttached: true, hasProcess: true))
}

@Test func retryNeverStartsWithoutAnAttachedAgent() {
    #expect(!RetryAdoptionPolicy.shouldRun(
        sessionIsAlive: true, isAttached: false, hasProcess: false))
}

@Test func retryStopsWhenTheSessionDies() {
    #expect(!RetryAdoptionPolicy.shouldRun(
        sessionIsAlive: false, isAttached: true, hasProcess: false))
}
