//
//  RunMetricsProviding.swift
//  Weekly Plan
//

import Foundation

@MainActor
protocol RunMetricsProviding: AnyObject {
    var liveState: LiveRunState { get }
    var stateUpdates: AsyncStream<LiveRunState> { get }
}

@MainActor
protocol RunSessionLifecycle: AnyObject {
    func onRunStarted(plannedRun: PlannedRun, profile: OnboardingProfile)
    func onRunEnded()
}
