import Foundation

public enum LocationContinuityIssue: Equatable, Sendable {
    case tunnelClosed
    case setProcessStopped
    case healthCheckFailed
    case setProcessErrorOutput
    case deviceDisconnected
    case systemWake
}

public enum LocationContinuityAssessment: Equatable, Sendable {
    case active
    case uncertain(LocationContinuityIssue)

    public static func assess(
        tunnelRunning: Bool,
        setProcessRunning: Bool,
        tunnelHealthCheckSucceeded: Bool = true,
        setErrorOutputAdvanced: Bool = false
    ) -> LocationContinuityAssessment {
        if !setProcessRunning {
            return .uncertain(.setProcessStopped)
        }
        if !tunnelRunning {
            return .uncertain(.tunnelClosed)
        }
        if !tunnelHealthCheckSucceeded {
            return .uncertain(.healthCheckFailed)
        }
        if setErrorOutputAdvanced {
            return .uncertain(.setProcessErrorOutput)
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
    public let total: Int?

    public init(number: Int, total: Int?) {
        self.number = number
        self.total = total
    }
}

public struct LocationAutoRecoveryPolicy: Equatable, Sendable {
    public let maxAttempts: Int?
    public let retryDelaySeconds: TimeInterval
    public let maximumRetryDelaySeconds: TimeInterval
    public let backoffMultiplier: Double

    public init(
        maxAttempts: Int? = nil,
        retryDelaySeconds: TimeInterval = 10,
        maximumRetryDelaySeconds: TimeInterval = 120,
        backoffMultiplier: Double = 2
    ) {
        self.maxAttempts = maxAttempts
        self.retryDelaySeconds = retryDelaySeconds
        self.maximumRetryDelaySeconds = maximumRetryDelaySeconds
        self.backoffMultiplier = backoffMultiplier
    }

    public var keepsTryingUntilDeviceReturns: Bool {
        maxAttempts == nil
    }

    public var attempts: [LocationAutoRecoveryAttempt] {
        guard let maxAttempts, maxAttempts > 0 else {
            return []
        }
        return (1...maxAttempts).map { LocationAutoRecoveryAttempt(number: $0, total: maxAttempts) }
    }

    public func delayBeforeAttempt(_ attemptNumber: Int) -> TimeInterval? {
        guard attemptNumber >= 1 else {
            return nil
        }
        if let maxAttempts, attemptNumber > maxAttempts {
            return nil
        }
        guard attemptNumber > 1 else {
            return 0
        }

        let exponent = Double(attemptNumber - 2)
        let delay = retryDelaySeconds * pow(backoffMultiplier, exponent)
        return min(delay, maximumRetryDelaySeconds)
    }

    public func progressText(for attempt: LocationAutoRecoveryAttempt) -> String {
        if let total = attempt.total {
            return "自動再接続中です... \(attempt.number)/\(total)"
        }
        return "自動再接続中です... \(attempt.number)回目"
    }
}

public struct TunnelPreparationPolicy: Equatable, Sendable {
    public let timeoutSeconds: TimeInterval
    public let pollIntervalSeconds: TimeInterval

    public init(timeoutSeconds: TimeInterval = 60, pollIntervalSeconds: TimeInterval = 0.5) {
        self.timeoutSeconds = timeoutSeconds
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    public var maximumPollCount: Int {
        guard timeoutSeconds > 0, pollIntervalSeconds > 0 else {
            return 0
        }
        return Int((timeoutSeconds / pollIntervalSeconds).rounded(.up))
    }
}

public enum TunnelStateInvalidationPolicy {
    public static func shouldInvalidateTunnel(for error: Error) -> Bool {
        switch error {
        case LocateError.invalidCoordinate:
            return false
        case LocateError.invalidRSDOutput, LocateError.helperMissing:
            return true
        case LocateError.processControlFailed(let message),
             LocateError.invalidDeviceList(let message):
            return message.localizedCaseInsensitiveContains("No route to host") ||
                message.localizedCaseInsensitiveContains("Connection refused") ||
                message.localizedCaseInsensitiveContains("Connection reset") ||
                message.localizedCaseInsensitiveContains("Broken pipe") ||
                message.localizedCaseInsensitiveContains("tunnel") ||
                message.localizedCaseInsensitiveContains("RSD") ||
                message.localizedCaseInsensitiveContains("iPhoneに接続できません")
        default:
            return false
        }
    }
}

public enum LocationAutoRecoveryErrorClassifier {
    public static func isUserCancellation(_ message: String) -> Bool {
        let normalizedMessage = message.lowercased()
        return normalizedMessage.contains("user canceled") ||
            message.localizedCaseInsensitiveContains("キャンセル") ||
            normalizedMessage.contains("(-128)")
    }
}

public enum LocationAutoRecoveryTunnelPolicy {
    public static func shouldForceRestart(for issue: LocationContinuityIssue) -> Bool {
        switch issue {
        case .tunnelClosed, .healthCheckFailed, .deviceDisconnected, .systemWake:
            return true
        case .setProcessStopped, .setProcessErrorOutput:
            return false
        }
    }
}
