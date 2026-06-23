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

public struct AppLaunchUpdateCheckPolicy: Equatable, Sendable {
    public init() {}

    public static func shouldCheckOnLaunch(automaticallyChecksForUpdates: Bool) -> Bool {
        automaticallyChecksForUpdates
    }
}

public struct LocationAutoRecoveryAttempt: Equatable, Sendable {
    public let number: Int
    public let total: Int

    public init(number: Int, total: Int) {
        self.number = number
        self.total = total
    }
}

public struct LocationAutoRecoveryPolicy: Equatable, Sendable {
    public let maxAttempts: Int
    public let retryDelaySeconds: TimeInterval

    public init(maxAttempts: Int = 3, retryDelaySeconds: TimeInterval = 10) {
        self.maxAttempts = maxAttempts
        self.retryDelaySeconds = retryDelaySeconds
    }

    public var attempts: [LocationAutoRecoveryAttempt] {
        guard maxAttempts > 0 else {
            return []
        }
        return (1...maxAttempts).map { LocationAutoRecoveryAttempt(number: $0, total: maxAttempts) }
    }

    public func delayBeforeAttempt(_ attemptNumber: Int) -> TimeInterval? {
        guard attemptNumber >= 1, attemptNumber <= maxAttempts else {
            return nil
        }
        return attemptNumber == 1 ? 0 : retryDelaySeconds
    }

    public func progressText(for attempt: LocationAutoRecoveryAttempt) -> String {
        "自動再接続中です... \(attempt.number)/\(attempt.total)"
    }
}

public enum LocationAutoRecoveryErrorClassifier {
    public static func isUserCancellation(_ message: String) -> Bool {
        let normalizedMessage = message.lowercased()
        return normalizedMessage.contains("user canceled") ||
            message.localizedCaseInsensitiveContains("キャンセル") ||
            normalizedMessage.contains("(-128)") ||
            normalizedMessage.contains("osascript error -128")
    }
}
