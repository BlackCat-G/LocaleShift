import Foundation
import Darwin
import LocaleShiftCore
import LocaleShiftSystem

/// Only included in explicitly built local test packages; all mutations still use
/// the production user-agent protocol and SwitchEngine with durable responsibility.
enum LocalDevelopmentCommands {
    static func emit<T: Encodable>(_ stage: String, _ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
        let data = try JSONSerialization.data(withJSONObject: ["stage": stage, "value": payload], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self)); fflush(stdout)
    }
    static func request(_ request: UserRequest) async throws -> UserReply {
        let result = try await XPCClient.user(request)
        try emit(request.action.rawValue, result)
        if let error = result.error { throw error }
        if let operation = result.operation, !operation.succeeded { throw operation.error ?? CoreError(.readbackMismatch) }
        return result
    }
    static func run(_ command: String) async throws {
        guard RuntimePaths.localDevelopment, PeerTrust.canModifySystem else {
            throw CoreError(.permissionDenied, detail: "只能从经管理员批准的固定安装副本执行本机测试。")
        }
        switch command {
        case "io-probe":
            let report = try await LocalPerformanceProbe.run(iterations: 1_800, switchPages: false)
            try emit("io-probe", report)
        case "trust-cache-watch":
            let before = LocalDevelopmentTrust.validationMetrics
            try emit("trust-cache-waiting", before)
            for _ in 0..<200 {
                try await Task.sleep(nanoseconds: 100_000_000)
                guard PeerTrust.canModifySystem else { throw CoreError(.permissionDenied) }
                let after = LocalDevelopmentTrust.validationMetrics
                if after.fullChecks > before.fullChecks { try emit("trust-cache-invalidated", after); return }
            }
            throw CoreError(.transientUnavailable, detail: "No metadata change observed during cache acceptance.")
        case "trust-cache":
            let before = LocalDevelopmentTrust.validationMetrics
            let started = ProcessInfo.processInfo.systemUptime
            for _ in 0..<100 { guard PeerTrust.canModifySystem else { throw CoreError(.permissionDenied) } }
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            let after = LocalDevelopmentTrust.validationMetrics
            try emit("trust-cache-before", before); try emit("trust-cache-after", after)
            try emit("trust-cache-milliseconds", elapsed)
            guard before.fullChecks == after.fullChecks, after.cacheHits >= before.cacheHits + 100 else { throw CoreError(.invalidTarget) }
        case "performance":
            let report = try await LocalPerformanceProbe.run()
            try emit("performance", report)
        case "register":
            try Services.registerProtection(); try emit("registration", Services.status())
        case "status":
            try emit("registration", Services.status())
            try emit("root", await XPCClient.root(RootRequest(.status)))
            _ = try await request(UserRequest(.status))
        case "restore":
            _ = try await request(UserRequest(.restore, confirmedActual: NativePreferences.read()))
        case "unregister":
            let repository = try Repository(directory: RuntimePaths.userData)
            guard try repository.activeSession() == nil,
                  try repository.operations().allSatisfy({ $0.completedAt != nil }) else { throw CoreError(.sessionUnresolved) }
            if let baseline = try repository.baseline() {
                guard try NativePreferences.read().matches(baseline.settings) else { throw CoreError(.readbackMismatch) }
            }
            if Services.status().timezoneService == 1 {
                let root = try await XPCClient.root(RootRequest(.status))
                guard root.available, root.ownerSessionID == nil else { throw CoreError(.sessionUnresolved) }
            }
            if Services.agent.status == .enabled || Services.agent.status == .requiresApproval { try await Services.agent.unregister() }
            if Services.root.status == .enabled || Services.root.status == .requiresApproval { try await Services.root.unregister() }
            if Services.status().loginEnabled { try Services.setLoginEnabled(false) }
            try emit("unregistered", Services.status())
        case "validate-switch":
            guard CommandLine.arguments.contains("--automatic-timezone-disabled") else { throw CoreError(.preparationRequired, detail: "请先手动关闭自动时区，再显式提供确认参数。此参数不检测或修改开关。") }
            guard Services.status().ready else { throw CoreError(.protectionUnavailable) }
            let before = try NativePreferences.read()
            try emit("before", before)
            let initial = try await request(UserRequest(.status))
            guard initial.snapshot?.session == nil else { throw CoreError(.sessionUnresolved) }
            if let baseline = initial.snapshot?.baseline {
                guard before.matches(baseline.settings) else { throw CoreError(.readbackMismatch, detail: "请先恢复已有默认配置，再执行验收。") }
            } else { _ = try await request(UserRequest(.saveBaseline, settings: before)) }
            _ = try await request(UserRequest(.confirmPreparation))
            var failure: Error?
            do {
                for profile in [WorkProfile(language: "en-US", region: "US", timeZone: "America/New_York"),
                                WorkProfile(language: "ja-JP", region: "JP", timeZone: "Asia/Tokyo")] {
                    let actual = try NativePreferences.read()
                    let target = try profile.applying(to: actual)
                    _ = try await request(UserRequest(.apply, profile: profile, confirmedActual: actual))
                    let readback = try NativePreferences.read()
                    try emit("actual-switched", readback)
                    guard readback.matches(target) else { throw CoreError(.readbackMismatch) }
                }
            } catch { failure = error }
            // Restore even after partial failure; a failed restore preserves service responsibility.
            _ = try await request(UserRequest(.restore, confirmedActual: NativePreferences.read()))
            let after = try NativePreferences.read()
            try emit("after", after)
            guard after.matches(before) else { throw CoreError(.readbackMismatch) }
            if let failure { throw failure }
        default: throw CoreError(.invalidTarget, detail: "未知本机测试命令。")
        }
    }
}
