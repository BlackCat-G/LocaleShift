import Foundation
import LocaleShiftCore

@objc public protocol UserServiceProtocol {
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}
@objc public protocol TimezoneServiceProtocol {
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

public enum UserAction: String, Codable {
    case status, apply, restore, confirmPreparation, clearPreparation, recover, pauseRecovery, saveBaseline, saveProfile, deleteProfile
}
public struct UserRequest: Codable {
    public var version = RuntimePaths.protocolVersion
    public var action: UserAction
    public var profile: WorkProfile?
    public var profileID: UUID?
    public var settings: SystemSettings?
    public var confirmedActual: SystemSettings?
    public init(_ action: UserAction, profile: WorkProfile? = nil, profileID: UUID? = nil,
                settings: SystemSettings? = nil, confirmedActual: SystemSettings? = nil) {
        self.action = action; self.profile = profile; self.profileID = profileID
        self.settings = settings; self.confirmedActual = confirmedActual
    }
}
public struct AgentSnapshot: Codable {
    public var actual: SystemSettings?
    public var baseline: DefaultBaseline?
    public var session: WorkSession?
    public var preparation: TimezonePreparation
    public var protection: ProtectionStatus
    public var capabilities: EngineCapabilities
    public var profiles: [WorkProfile]
    public var history: [OperationRecord]
    public var requiresManualVerification: Bool
    public var recoveryBackupBaseline: DefaultBaseline?
    public var error: CoreError?
    public init(_ status: EngineStatus, history: [OperationRecord]) {
        actual = status.actual; baseline = status.baseline; session = status.session
        preparation = status.preparation; protection = status.protection; capabilities = status.capabilities
        requiresManualVerification = status.recoveryBackup != nil; recoveryBackupBaseline = status.recoveryBackup?.baseline
        profiles = status.profiles; error = status.error; self.history = history
    }
}
public struct UserReply: Codable {
    public var version = RuntimePaths.protocolVersion
    public var snapshot: AgentSnapshot?
    public var operation: OperationRecord?
    public var error: CoreError?
    public init(snapshot: AgentSnapshot? = nil, operation: OperationRecord? = nil, error: CoreError? = nil) {
        self.snapshot = snapshot; self.operation = operation; self.error = error
    }
}
public enum RootAction: String, Codable { case status, claim, write, release, pauseRecovery, recordRecoveryFailure }
public struct RootRequest: Codable {
    public var version = RuntimePaths.protocolVersion
    public var action: RootAction
    public var sessionID: UUID?
    public var baselineVersion: UUID?
    public var baselineTimeZone: String?
    public var expectedTimeZone: String?
    public var targetTimeZone: String?
    public var process: ProcessIdentity?
    public var recoveryOperation = false
    public var automaticRecovery = false
    public var recoveryRetryAt: Date?
    public var recoveryError: CoreError?
    public var recoveryAttempts = 0
    public var operationID: UUID?
    public var confirmedExternalChange = false
    public init(_ action: RootAction, sessionID: UUID? = nil, baselineVersion: UUID? = nil,
        baselineTimeZone: String? = nil, expectedTimeZone: String? = nil, targetTimeZone: String? = nil, process: ProcessIdentity? = nil,
        confirmedExternalChange: Bool = false, operationID: UUID? = nil, automaticRecovery: Bool = false, recoveryAttempts: Int = 0, recoveryOperation: Bool = false, recoveryRetryAt: Date? = nil, recoveryError: CoreError? = nil) {
        self.action = action; self.sessionID = sessionID; self.baselineVersion = baselineVersion
        self.baselineTimeZone = baselineTimeZone; self.expectedTimeZone = expectedTimeZone
        self.targetTimeZone = targetTimeZone; self.process = process
        self.confirmedExternalChange = confirmedExternalChange; self.operationID = operationID
        self.recoveryRetryAt = recoveryRetryAt; self.recoveryError = recoveryError
        self.recoveryOperation = recoveryOperation; self.automaticRecovery = automaticRecovery; self.recoveryAttempts = recoveryAttempts
    }
}
public struct RootReply: Codable {
    public var version = RuntimePaths.protocolVersion
    public var available: Bool
    public var actualTimeZone: String
    public var ownerUID: UInt32?
    public var ownerSessionID: UUID?
    public var error: CoreError?
    public var recoveryAttempts: Int
    public var recoveryRetryAt: Date?
    public var restoredBaseline: Bool
    public var baselineVersion: UUID?
    public init(available: Bool, actualTimeZone: String, ownerUID: UInt32? = nil, ownerSessionID: UUID? = nil, error: CoreError? = nil, restoredBaseline: Bool = false, baselineVersion: UUID? = nil, recoveryAttempts: Int = 0, recoveryRetryAt: Date? = nil) {
        self.available = available; self.actualTimeZone = actualTimeZone
        self.ownerUID = ownerUID; self.ownerSessionID = ownerSessionID; self.error = error; self.restoredBaseline = restoredBaseline; self.baselineVersion = baselineVersion
        self.recoveryAttempts = recoveryAttempts; self.recoveryRetryAt = recoveryRetryAt
    }
}

final class ReplyOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Result<T, Error>) -> Void)?
    init(_ completion: @escaping (Result<T, Error>) -> Void) { self.completion = completion }
    func finish(_ result: Result<T, Error>) {
        lock.lock(); let callback = completion; completion = nil; lock.unlock()
        callback?(result)
    }
}

public enum XPCClient {
    public static func user(_ request: UserRequest) async throws -> UserReply {
        guard let requirement = PeerTrust.requirement(for: RuntimePaths.agentID, executable: "LocaleShiftUserAgent", privileged: false) else {
            throw CoreError(.permissionDenied, detail: "后台程序身份无法核验。")
        }
        let payload = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: RuntimePaths.agentID)
            connection.remoteObjectInterface = NSXPCInterface(with: UserServiceProtocol.self)
            connection.setCodeSigningRequirement(requirement)
            let once = ReplyOnce<UserReply> { result in connection.invalidate(); continuation.resume(with: result) }
            connection.invalidationHandler = { once.finish(.failure(CoreError(.transientUnavailable))) }
            connection.interruptionHandler = { once.finish(.failure(CoreError(.transientUnavailable))) }
            connection.activate()
            guard let remote = connection.remoteObjectProxyWithErrorHandler({ _ in once.finish(.failure(CoreError(.transientUnavailable))) }) as? UserServiceProtocol else {
                once.finish(.failure(CoreError(.transientUnavailable))); return
            }
            remote.perform(payload) { data in
                do {
                    let reply = try JSONDecoder().decode(UserReply.self, from: data)
                    guard reply.version == RuntimePaths.protocolVersion else { throw CoreError(.capabilityUnavailable, detail: "服务版本不兼容。") }
                    once.finish(.success(reply))
                } catch { once.finish(.failure(error)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 45) { once.finish(.failure(CoreError(.transientUnavailable))) }
        }
    }
    public static func root(_ request: RootRequest) async throws -> RootReply {
        guard let requirement = PeerTrust.requirement(for: RuntimePaths.rootID, executable: "LocaleShiftTimezoneService", privileged: true) else {
            throw CoreError(.permissionDenied, detail: "系统修改需要可信签名的恢复服务；当前开发包保留只读能力。")
        }
        let payload = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: RuntimePaths.rootID, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: TimezoneServiceProtocol.self)
            connection.setCodeSigningRequirement(requirement)
            let once = ReplyOnce<RootReply> { result in connection.invalidate(); continuation.resume(with: result) }
            connection.invalidationHandler = { once.finish(.failure(CoreError(.transientUnavailable))) }
            connection.activate()
            guard let remote = connection.remoteObjectProxyWithErrorHandler({ _ in once.finish(.failure(CoreError(.transientUnavailable))) }) as? TimezoneServiceProtocol else {
                once.finish(.failure(CoreError(.transientUnavailable))); return
            }
            remote.perform(payload) { data in
                do {
                    let reply = try JSONDecoder().decode(RootReply.self, from: data)
                    guard reply.version == RuntimePaths.protocolVersion else { throw CoreError(.capabilityUnavailable) }
                    if let error = reply.error { throw error }
                    once.finish(.success(reply))
                } catch { once.finish(.failure(error)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { once.finish(.failure(CoreError(.transientUnavailable))) }
        }
    }
}
