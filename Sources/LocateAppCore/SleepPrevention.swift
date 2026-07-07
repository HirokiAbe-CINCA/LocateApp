import Foundation
import IOKit.pwr_mgt

public enum SleepPreventionError: Error, Equatable, LocalizedError, Sendable {
    case assertionCreationFailed(IOReturn)

    public var errorDescription: String? {
        switch self {
        case .assertionCreationFailed(let code):
            return "Could not prevent Mac sleep while location simulation is active: IOReturn \(code)"
        }
    }
}

public protocol SleepAssertionClient: Sendable {
    func create(reason: String) throws -> UInt32
    func release(id: UInt32)
}

public struct IOKitSleepAssertionClient: SleepAssertionClient {
    public init() {}

    public func create(reason: String) throws -> UInt32 {
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            throw SleepPreventionError.assertionCreationFailed(result)
        }
        return assertionID
    }

    public func release(id: UInt32) {
        IOPMAssertionRelease(IOPMAssertionID(id))
    }
}

public final class SleepPreventer: @unchecked Sendable {
    private let client: SleepAssertionClient
    private let reason: String
    private let lock = NSLock()
    private var assertionID: UInt32?

    public init(
        client: SleepAssertionClient = IOKitSleepAssertionClient(),
        reason: String = "LocateApp is maintaining iPhone location simulation"
    ) {
        self.client = client
        self.reason = reason
    }

    deinit {
        release()
    }

    public var isActive: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return assertionID != nil
    }

    public func acquire() throws {
        lock.lock()
        if assertionID != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        let newAssertionID = try client.create(reason: reason)

        lock.lock()
        if assertionID == nil {
            assertionID = newAssertionID
            lock.unlock()
        } else {
            lock.unlock()
            client.release(id: newAssertionID)
        }
    }

    public func release() {
        lock.lock()
        let activeAssertionID = assertionID
        assertionID = nil
        lock.unlock()

        if let activeAssertionID {
            client.release(id: activeAssertionID)
        }
    }
}

public protocol AppActivityClient: Sendable {
    func begin(reason: String) -> AnyObject
    func end(_ token: AnyObject)
}

public struct ProcessInfoActivityClient: AppActivityClient {
    public init() {}

    public func begin(reason: String) -> AnyObject {
        ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: reason
        ) as AnyObject
    }

    public func end(_ token: AnyObject) {
        guard let activity = token as? NSObjectProtocol else {
            return
        }
        ProcessInfo.processInfo.endActivity(activity)
    }
}

public final class AppNapPreventer: @unchecked Sendable {
    private let client: AppActivityClient
    private let reason: String
    private let lock = NSLock()
    private var activityToken: AnyObject?

    public init(
        client: AppActivityClient = ProcessInfoActivityClient(),
        reason: String = "LocateApp is maintaining iPhone location simulation"
    ) {
        self.client = client
        self.reason = reason
    }

    deinit {
        release()
    }

    public var isActive: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return activityToken != nil
    }

    public func acquire() {
        lock.lock()
        if activityToken != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        let newToken = client.begin(reason: reason)

        lock.lock()
        if activityToken == nil {
            activityToken = newToken
            lock.unlock()
        } else {
            lock.unlock()
            client.end(newToken)
        }
    }

    public func release() {
        lock.lock()
        let activeToken = activityToken
        activityToken = nil
        lock.unlock()

        if let activeToken {
            client.end(activeToken)
        }
    }
}
