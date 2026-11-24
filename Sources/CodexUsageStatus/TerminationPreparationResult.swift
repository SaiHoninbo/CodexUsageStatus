/// Result of the bounded persistence hand-off used by AppKit termination.
/// A timeout or failed write must never be treated as a successful save.
@_spi(CodexUsageStatusPlanLoopIntegration)
public enum CodexUsageTerminationPreparationResult: Equatable, Sendable {
    case saved
    case persistenceFailure
    case timedOut

    public var shouldTerminate: Bool { self == .saved }
}
