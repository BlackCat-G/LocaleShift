import Foundation
import Darwin

public enum SettingField: String, Codable, CaseIterable, Sendable { case languages, region, timeZone }

public struct SystemSettings: Codable, Equatable, Sendable {
    public var languages: [String]
    public var region: String
    public var timeZone: String
    public init(languages: [String], region: String, timeZone: String) {
        self.languages = languages; self.region = region; self.timeZone = timeZone
    }
    public func matches(_ other: Self, field: SettingField) -> Bool {
        switch field {
        case .languages: return languages.map(IdentifierNormalizer.language) == other.languages.map(IdentifierNormalizer.language)
        case .region: return IdentifierNormalizer.canonicalRegion(region) == IdentifierNormalizer.canonicalRegion(other.region)
        case .timeZone: return (try? IdentifierNormalizer.timeZone(timeZone)) == (try? IdentifierNormalizer.timeZone(other.timeZone)) && TimeZone(identifier: timeZone) != nil
        }
    }
    public func matches(_ other: Self) -> Bool { SettingField.allCases.allSatisfy { matches(other, field: $0) } }
    public mutating func copy(_ field: SettingField, from settings: Self) {
        switch field { case .languages: languages = settings.languages; case .region: region = settings.region; case .timeZone: timeZone = settings.timeZone }
    }
    public func validated() throws -> Self {
        guard !languages.isEmpty, languages.allSatisfy(IdentifierNormalizer.isValidLanguage), IdentifierNormalizer.isValidRegion(region) else { throw CoreError(.invalidTarget) }
        _ = try IdentifierNormalizer.timeZone(timeZone)
        return self
    }
}

public struct ProcessIdentity: Codable, Equatable, Hashable, Sendable {
    public var pid: Int32
    public var startSeconds: Int64
    public var startMicroseconds: Int32
    public var bootID: String
    public init(pid: Int32, startSeconds: Int64, startMicroseconds: Int32, bootID: String) {
        self.pid = pid; self.startSeconds = startSeconds; self.startMicroseconds = startMicroseconds; self.bootID = bootID
    }
}

public enum CoreErrorCode: String, Codable, Sendable {
    case invalidTarget, duplicateProfile, baselineMissing, dataCorrupt, persistence, busy, previewChanged, preparationRequired, protectionUnavailable, capabilityUnavailable, permissionDenied, ownershipConflict, externalChange, readbackMismatch, transientUnavailable, recoveryExhausted, recoveryNotDue, sessionUnresolved, restartUnverified
    public var isTerminalRecovery: Bool {
        switch self { case .permissionDenied, .dataCorrupt, .baselineMissing, .ownershipConflict, .externalChange, .invalidTarget, .restartUnverified: return true; default: return false }
    }
}
public struct CoreError: Error, Codable, Equatable, LocalizedError, Sendable {
    public var code: CoreErrorCode
    public var detail: String
    public var field: SettingField?
    public init(_ code: CoreErrorCode, detail: String = "", field: SettingField? = nil) { self.code = code; self.detail = detail; self.field = field }
    public var errorDescription: String? { message }
    public var message: String {
        let text: String
        switch code {
        case .invalidTarget: text = "设置值无效，请重新选择。"
        case .duplicateProfile: text = "这套语言、地区和时区设置已经保存。"
        case .baselineMissing: text = "请先确认并保存系统默认配置。"
        case .dataCorrupt: text = "恢复记录损坏，无法确定恢复目标，请手动处理。"
        case .persistence: text = "无法可靠保存恢复记录，已停止修改。"
        case .busy: text = "另一个设置操作正在进行，请稍后重试。"
        case .previewChanged: text = "实际系统设置已变化，请重新查看预览并确认。"
        case .preparationRequired: text = "请先手动关闭自动时区，并确认时区准备。"
        case .protectionUnavailable: text = "后台恢复保护不可用，已暂停新的工作切换。"
        case .capabilityUnavailable: text = "当前环境尚未通过此项修改能力验证。"
        case .permissionDenied: text = "授权被拒绝或已撤销，请在前台处理。"
        case .ownershipConflict: text = "其他会话正在使用系统时区，请先处理原会话。"
        case .externalChange: text = "检测到记录之外的系统设置变化，已暂停自动覆盖。"
        case .readbackMismatch: text = "实际读回值与目标不一致，设置尚未完成。"
        case .transientUnavailable: text = "系统服务暂时不可用。"
        case .recoveryExhausted: text = "自动恢复已尝试三次，请手动处理。"
        case .recoveryNotDue: text = "尚未到达下一次恢复时间。"
        case .sessionUnresolved: text = "仍有工作会话或恢复事项，请先恢复系统默认。"
        case .restartUnverified: text = "尚无法可靠验证紧邻的下一次启动，无法继续工作设置。"
        }
        return detail.isEmpty ? text : "\(text) \(detail)"
    }
}

public struct ProtectionStatus: Codable, Equatable, Sendable {
    public var available: Bool
    public var message: String
    public init(available: Bool, message: String = "") { self.available = available; self.message = message }
}
public struct EngineCapabilities: Codable, Equatable, Sendable {
    public var languageWrite: Bool; public var regionWrite: Bool; public var timeZoneWrite: Bool
    public var backgroundRecovery: Bool; public var restartContinuation: Bool
    public init(languageWrite: Bool = false, regionWrite: Bool = false, timeZoneWrite: Bool = false, backgroundRecovery: Bool = false, restartContinuation: Bool = false) {
        self.languageWrite = languageWrite; self.regionWrite = regionWrite; self.timeZoneWrite = timeZoneWrite; self.backgroundRecovery = backgroundRecovery; self.restartContinuation = restartContinuation
    }
    public var canApply: Bool { languageWrite && regionWrite && timeZoneWrite && backgroundRecovery }
}
public protocol SystemSettingsAdapter: Sendable {
    func read() async throws -> SystemSettings
    func checkProtection() async -> ProtectionStatus
    func beginOwnership(sessionID: UUID, baselineVersion: UUID, process: ProcessIdentity) async throws
    func write(field: SettingField, settings: SystemSettings, operationID: UUID, sessionID: UUID) async throws
    func release(sessionID: UUID) async throws
}

public struct WorkProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var language: String
    public var region: String
    public var timeZone: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastAppliedAt: Date?
    public var title: String { ProfileTitle.make(region: region, timeZone: timeZone) }
    public init(id: UUID = UUID(), language: String, region: String, timeZone: String, createdAt: Date = Date(), updatedAt: Date = Date(), lastAppliedAt: Date? = nil) {
        self.id = id; self.language = language; self.region = region; self.timeZone = timeZone; self.createdAt = createdAt; self.updatedAt = updatedAt; self.lastAppliedAt = lastAppliedAt
    }
    public func applying(to actual: SystemSettings) throws -> SystemSettings {
        var value = actual
        value.languages = IdentifierNormalizer.orderedLanguages(target: language, existing: actual.languages)
        value.region = IdentifierNormalizer.applyingRegion(region, preserving: actual.region)
        value.timeZone = try IdentifierNormalizer.timeZone(timeZone)
        return try value.validated()
    }
}
public struct DefaultBaseline: Codable, Equatable, Sendable {
    public var version: UUID
    public var settings: SystemSettings
    public var source: String
    public var confirmedAt: Date
    public var formatVersion: Int
    public init(version: UUID = UUID(), settings: SystemSettings, source: String, confirmedAt: Date = Date(), formatVersion: Int = 1) {
        self.version = version; self.settings = settings; self.source = source; self.confirmedAt = confirmedAt; self.formatVersion = formatVersion
    }
}
public enum SessionState: String, Codable, Sendable { case working, recovering, needsAttention, waitingForRestart, handoff }
/// Attach only after the coordinator verifies an authenticated machine-service recovery receipt.
public struct TimeZoneRecoveryReceipt: Codable, Equatable, Sendable {
    public var ownerUID: UInt32
    public var sessionID: UUID
    public var baselineVersion: UUID
    public var timeZone: String
    public init(ownerUID: UInt32, sessionID: UUID, baselineVersion: UUID, timeZone: String) {
        self.ownerUID = ownerUID; self.sessionID = sessionID; self.baselineVersion = baselineVersion; self.timeZone = timeZone
    }
}
public struct WorkSession: Codable, Equatable, Identifiable, Sendable {
    public var ownerUID: UInt32
    public var id: UUID
    public var baselineVersion: UUID
    public var process: ProcessIdentity
    public var target: SystemSettings
    public var targetTitle: String
    public var lastKnownActual: SystemSettings
    public var timeZoneRecoveryReceipt: TimeZoneRecoveryReceipt? = nil
    public var state: SessionState
    public var createdAt: Date
    public var recoveryAttempts: Int
    public var recoveryDueAt: Date?
    public var recoveryTerminal: Bool
    public var error: CoreError?
    public init(id: UUID = UUID(), baselineVersion: UUID, process: ProcessIdentity, target: SystemSettings, targetTitle: String, lastKnownActual: SystemSettings, state: SessionState = .working, createdAt: Date = Date(), ownerUID: UInt32 = UInt32(getuid())) {
        self.ownerUID = ownerUID; self.id = id; self.baselineVersion = baselineVersion; self.process = process; self.target = target; self.targetTitle = targetTitle; self.lastKnownActual = lastKnownActual; self.state = state; self.createdAt = createdAt
        recoveryAttempts = 0; recoveryDueAt = nil; recoveryTerminal = false; error = nil
    }
}
public enum OperationKind: String, Codable, Sendable { case apply, restore, recovery }
public enum OperationState: String, Codable, Sendable { case recorded, executing, verifying, completed, rollingBack, rolledBack, needsAttention }
public enum StepState: String, Codable, Sendable { case pending, intentSaved, verified, rollbackIntentSaved, rolledBack, failed }
public struct OperationStep: Codable, Equatable, Identifiable, Sendable {
    public var field: SettingField
    public var state: StepState
    public var lastWriteIntent: StepState?
    public var readback: SystemSettings?
    public var error: CoreError?
    public var id: SettingField { field }
    public init(field: SettingField, state: StepState = .pending) { self.field = field; self.state = state }
}
public struct OperationRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var baselineVersion: UUID
    public var kind: OperationKind
    public var title: String
    public var before: SystemSettings
    public var target: SystemSettings
    public var createdAt: Date
    public var completedAt: Date?
    public var state: OperationState
    public var steps: [OperationStep]
    public var error: CoreError?
    public var relatedOperationID: UUID?
    public init(id: UUID = UUID(), sessionID: UUID, baselineVersion: UUID, kind: OperationKind, title: String, before: SystemSettings, target: SystemSettings, createdAt: Date = Date()) {
        self.id = id; self.sessionID = sessionID; self.baselineVersion = baselineVersion; self.kind = kind; self.title = title; self.before = before; self.target = target; self.createdAt = createdAt
        self.state = .recorded; self.steps = SettingField.allCases.map { OperationStep(field: $0) }
    }
    public var succeeded: Bool { state == .completed }
}
public struct TimezonePreparation: Codable, Equatable, Sendable {
    public var userConfirmed: Bool
    public var guideVersion: Int
    public var confirmedAt: Date?
    public init(userConfirmed: Bool = false, guideVersion: Int = 1, confirmedAt: Date? = nil) { self.userConfirmed = userConfirmed; self.guideVersion = guideVersion; self.confirmedAt = confirmedAt }
}
public struct SwitchPreview: Codable, Equatable, Sendable {
    public var actual: SystemSettings
    public var target: SystemSettings
    public var title: String
    public var changedFields: [SettingField] { SettingField.allCases.filter { !actual.matches(target, field: $0) } }
    public init(actual: SystemSettings, target: SystemSettings, title: String) { self.actual = actual; self.target = target; self.title = title }
}
/// A complete recovery record set from one durable database transaction.
public struct RecoverySnapshot: Codable, Equatable, Sendable {
    public var formatVersion: Int = 1
    public var generation: UUID
    public var previousGeneration: UUID?
    public var baselineVersion: UUID?
    public var session: WorkSession?
    public var operations: [OperationRecord]
    public var restartIntent: RestartIntent?
    public var preparation: TimezonePreparation
}
public struct RecoverySnapshotEvidence: Equatable, Sendable {
    public var snapshot: RecoverySnapshot
    public var baseline: DefaultBaseline?
    public var isCurrent: Bool
    /// Backups are evidence, never implicit authorization to replay or roll back system settings.
    public var requiresManualVerification: Bool { true }
}
public struct EngineStatus: Sendable {
    public var actual: SystemSettings?
    public var baseline: DefaultBaseline?
    public var session: WorkSession?
    public var preparation: TimezonePreparation
    public var protection: ProtectionStatus
    public var capabilities: EngineCapabilities
    public var profiles: [WorkProfile]
    public var error: CoreError?
    public var hasUnresolvedOperations: Bool = false
    public var recoveryBackup: RecoverySnapshotEvidence? = nil
    public var canApply: Bool { baseline != nil && preparation.userConfirmed && protection.available && capabilities.canApply && (session == nil || session?.state == .working) && !hasUnresolvedOperations && error == nil }
}

public struct RestartIntent: Codable, Equatable, Sendable {
    public var ownerUID: UInt32
    public var id: UUID = UUID()
    public var sessionID: UUID
    public var baselineVersion: UUID
    public var sourceBootID: String
    public var createdAt: Date
    public var expiresAt: Date
    public var expected: SystemSettings
    public var normalRestartObserved: Bool = false
    public var targetBootID: String?
    public var handoffDeadlineUptime: TimeInterval?
    public var connected: Bool = false
    public var cancelled: Bool = false
    public init(sessionID: UUID, baselineVersion: UUID, sourceBootID: String, expected: SystemSettings, now: Date = Date(), ownerUID: UInt32 = UInt32(getuid())) {
        self.ownerUID = ownerUID; self.sessionID = sessionID; self.baselineVersion = baselineVersion; self.sourceBootID = sourceBootID; self.expected = expected; createdAt = now; expiresAt = now.addingTimeInterval(900)
    }
    public mutating func consume(targetBootID: String, targetBootTime: Date, uptime: TimeInterval, provenImmediateNextBoot: Bool, ownerUID: UInt32 = UInt32(getuid())) throws {
        guard self.ownerUID == ownerUID, !cancelled, normalRestartObserved, provenImmediateNextBoot, self.targetBootID == nil, targetBootID != sourceBootID, targetBootTime >= createdAt, targetBootTime <= expiresAt, uptime >= 0 else { throw CoreError(.restartUnverified) }
        self.targetBootID = targetBootID; handoffDeadlineUptime = uptime + 60
    }
    public func canConnect(bootID: String, uptime: TimeInterval, ownerUID: UInt32 = UInt32(getuid())) -> Bool { self.ownerUID == ownerUID && !cancelled && !connected && targetBootID == bootID && handoffDeadlineUptime.map { uptime >= 0 && uptime <= $0 } == true }
}
