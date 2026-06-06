import Foundation

public enum LocationContinuityIssue: Equatable, Sendable {
    case tunnelClosed
    case setProcessStopped
}

public enum LocationContinuityAssessment: Equatable, Sendable {
    case active
    case uncertain(LocationContinuityIssue)

    public static func assess(tunnelRunning: Bool, setProcessRunning: Bool) -> LocationContinuityAssessment {
        if !setProcessRunning {
            return .uncertain(.setProcessStopped)
        }
        if !tunnelRunning {
            return .uncertain(.tunnelClosed)
        }
        return .active
    }
}

public enum LocationReapplyPrompt {
    public static func isAvailable(hasActiveCoordinate: Bool, activeLocationMayRemain: Bool) -> Bool {
        hasActiveCoordinate && activeLocationMayRemain
    }
}
