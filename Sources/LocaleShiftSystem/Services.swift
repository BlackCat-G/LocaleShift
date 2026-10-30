import Foundation
import ServiceManagement
import AppKit
import LocaleShiftCore

public struct ServiceRegistrationStatus: Codable, Equatable, Sendable {
    public var userAgent: Int
    public var timezoneService: Int
    public var trustedSignature: Bool
    public var loginEnabled: Bool
    public var ready: Bool { userAgent == 1 && timezoneService == 1 && trustedSignature }
    public init(userAgent: Int = 0, timezoneService: Int = 0, trustedSignature: Bool = false, loginEnabled: Bool = false) {
        self.userAgent = userAgent; self.timezoneService = timezoneService
        self.trustedSignature = trustedSignature; self.loginEnabled = loginEnabled
    }
}

public enum Services {
    public static var agent: SMAppService { .agent(plistName: RuntimePaths.agentID + ".plist") }
    public static var root: SMAppService { .daemon(plistName: RuntimePaths.rootID + ".plist") }
    public static func status() -> ServiceRegistrationStatus {
        ServiceRegistrationStatus(userAgent: agent.status.rawValue, timezoneService: root.status.rawValue,
            trustedSignature: PeerTrust.canModifySystem, loginEnabled: SMAppService.mainApp.status == .enabled)
    }
    /// Signature verification and ServiceManagement IPC must never run in a SwiftUI getter.
    public static func statusInBackground() async -> ServiceRegistrationStatus {
        await Task.detached(priority: .userInitiated) { status() }.value
    }
    public static func registerProtectionInBackground() async throws {
        try await Task.detached(priority: .userInitiated) { try registerProtection() }.value
    }
    public static func setLoginEnabledInBackground(_ enabled: Bool) async throws {
        try await Task.detached(priority: .userInitiated) { try setLoginEnabled(enabled) }.value
    }
    /// Invoked only after the user elects to enable actual work switching.
    public static func registerProtection() throws {
        guard PeerTrust.canModifySystem else {
            throw CoreError(.permissionDenied, detail: "当前开发包尚未配置可信签名，暂不能启用系统修改。")
        }
        // A newly installed bundle can report notFound before its first registration.
        // Attempt the documented API and surface its error instead of silently succeeding.
        for service in [agent, root] where service.status == .notRegistered || service.status == .notFound {
            do { try service.register() }
            catch {
                // Pending system approval can be returned as EPERM. Keep the UI on
                // the approval path; ready still requires enabled services and XPC health.
                guard service.status == .requiresApproval else { throw error }
            }
        }
    }
    public static func setLoginEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
    public static func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
    @discardableResult public static func openDateAndTime() -> Bool {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension")!)
    }
    @discardableResult public static func openLanguageAndRegion() -> Bool {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
    }
}
