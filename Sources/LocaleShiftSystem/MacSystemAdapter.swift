import Foundation
import Darwin
import LocaleShiftCore

public final class MacSystemAdapter: SystemSettingsAdapter, @unchecked Sendable {
    private let repository: Repository
    private let allowExternalRestore: Bool
    private let automaticRecovery: Bool
    public init(repository: Repository, allowExternalRestore: Bool = false, automaticRecovery: Bool = false) {
        self.repository = repository; self.allowExternalRestore = allowExternalRestore; self.automaticRecovery = automaticRecovery
    }
    public func read() async throws -> SystemSettings { try NativePreferences.read() }
    public func checkProtection() async -> ProtectionStatus {
        let registration = Services.status()
        guard registration.ready else {
            return ProtectionStatus(available: false, message: registration.trustedSignature ?
                "恢复服务尚未获准运行，请在登录项中检查。" : "当前开发包未配置可信签名，配置管理和时间查看仍可使用。")
        }
        do {
            let health = try await XPCClient.root(RootRequest(.status))
            return ProtectionStatus(available: health.available, message: health.available ? "后台恢复可用" : "系统时区服务不可用。")
        } catch { return ProtectionStatus(available: false, message: error.localizedDescription) }
    }
    public func beginOwnership(sessionID: UUID, baselineVersion: UUID, process: ProcessIdentity) async throws {
        guard let baseline = try repository.baseline(), baseline.version == baselineVersion else { throw CoreError(.dataCorrupt) }
        _ = try await XPCClient.root(RootRequest(.claim, sessionID: sessionID, baselineVersion: baselineVersion,
            baselineTimeZone: baseline.settings.timeZone, expectedTimeZone: NativePreferences.actualTimeZone(), process: process, confirmedExternalChange: allowExternalRestore, automaticRecovery: automaticRecovery,
            recoveryAttempts: try repository.activeSession()?.recoveryAttempts ?? 0,
            recoveryOperation: try repository.activeSession()?.state != .working,
            recoveryRetryAt: try repository.activeSession()?.recoveryDueAt))
    }
    public func write(field: SettingField, settings: SystemSettings, operationID: UUID, sessionID: UUID) async throws {
        if field == .timeZone {
            _ = try await XPCClient.root(RootRequest(.write, sessionID: sessionID,
                expectedTimeZone: NativePreferences.actualTimeZone(), targetTimeZone: settings.timeZone,
                confirmedExternalChange: allowExternalRestore, operationID: operationID, automaticRecovery: automaticRecovery, recoveryAttempts: try repository.activeSession()?.recoveryAttempts ?? 0,
                recoveryRetryAt: try repository.activeSession()?.recoveryDueAt))
        } else {
            guard PeerTrust.canModifySystem else { throw CoreError(.permissionDenied) }
            if field == .languages, let language = settings.languages.first, !NativePreferences.supportsLanguage(language) {
                throw CoreError(.invalidTarget, detail: "此 Mac 没有可核验的目标系统语言支持。", field: .languages)
            }
            do { try NativePreferences.write(field, settings: settings) }
            catch { throw CoreError(.readbackMismatch, detail: error.localizedDescription, field: field) }
        }
    }
    public func release(sessionID: UUID) async throws {
        _ = try await XPCClient.root(RootRequest(.release, sessionID: sessionID))
    }
}
