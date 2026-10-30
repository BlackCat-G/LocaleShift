import Foundation
import AppKit
import Darwin
import OSLog
import LocaleShiftCore
import LocaleShiftSystem

let log = Logger(subsystem: RuntimePaths.agentID, category: "recovery")
let capabilities = VerifiedCapabilities.current

actor UserCoordinator {
    let repository: Repository
    init(repository: Repository) { self.repository = repository }
    func engine(process: ProcessIdentity, allowExternal: Bool = false, automaticRecovery: Bool = false) -> SwitchEngine {
        SwitchEngine(repository: repository, adapter: MacSystemAdapter(repository: repository, allowExternalRestore: allowExternal, automaticRecovery: automaticRecovery),
            process: process, capabilities: capabilities)
    }
    func perform(_ request: UserRequest, process: ProcessIdentity) async -> UserReply {
        let engine = engine(process: process, allowExternal: request.action == .restore && request.confirmedActual != nil)
        if request.action == .status { await inspect() }
        var operation: OperationRecord?
        var failure: CoreError?
        do {
            guard request.version == RuntimePaths.protocolVersion else { throw CoreError(.capabilityUnavailable) }
            switch request.action {
            case .status: break
            case .apply:
                if let old = try repository.activeSession(), old.process != process,
                   ProcessInspector.liveness(old.process, uid: getuid()) == .dead {
                    try await reconcileRootRecovery()
                    _ = try await runRecovery(process: process)
                    throw CoreError(.previewChanged, detail: "请先查看上次会话的恢复结果。")
                }
                if let old = try repository.activeSession(), ProcessInspector.liveness(old.process, uid: getuid()) == .unknown { throw CoreError(.protectionUnavailable, detail: "无法核验上次主进程，请先处理恢复。") }
                guard let profile = request.profile, let preview = request.confirmedActual else { throw CoreError(.invalidTarget) }
                operation = try await engine.apply(profile: profile, confirmedActual: preview)
            case .restore: operation = try await engine.restore(confirmedActual: request.confirmedActual)
            case .recover: try await reconcileRootRecovery(); operation = try await runRecovery(process: process)
            case .pauseRecovery:
                let lock = try CrossProcessLock(url: repository.lockURL).acquire(); defer { lock.unlock() }
                if var current = try repository.activeSession() {
                    _ = try await XPCClient.root(RootRequest(.pauseRecovery, sessionID: current.id))
                    current.state = .needsAttention; current.recoveryTerminal = true
                    current.error = CoreError(.sessionUnresolved, detail: "已由用户选择暂不恢复。")
                    try repository.saveSession(current)
                }
            case .confirmPreparation: try await engine.confirmTimezonePreparation()
            case .clearPreparation:
                let lock = try CrossProcessLock(url: repository.lockURL).acquire(); defer { lock.unlock() }
                try repository.saveTimezonePreparation(TimezonePreparation())
            case .saveBaseline:
                guard let settings = request.settings else { throw CoreError(.invalidTarget) }
                try await engine.updateBaseline(settings: settings, source: "用户明确确认")
            case .saveProfile:
                guard let profile = request.profile else { throw CoreError(.invalidTarget) }
                _ = try repository.saveProfile(profile)
            case .deleteProfile:
                guard let id = request.profileID else { throw CoreError(.invalidTarget) }
                try repository.deleteProfile(id: id)
            }
        } catch { failure = error as? CoreError ?? CoreError(.transientUnavailable, detail: error.localizedDescription) }
        return UserReply(snapshot: AgentSnapshot(await engine.status(), history: (try? repository.operations()) ?? []),
            operation: operation, error: failure)
    }
    func runRecovery(process: ProcessIdentity) async throws -> OperationRecord {
        guard let session = try repository.activeSession(), ProcessInspector.liveness(session.process, uid: getuid()) == .dead else { throw CoreError(.protectionUnavailable, detail: "尚未确认原主进程已结束，不能自动恢复。") }
        do {
            let operation = try await engine(process: process, automaticRecovery: true).recover(now: Date())
            if !operation.succeeded { await publishRecoveryFailure() }
            return operation
        } catch { await publishRecoveryFailure(); throw error }
    }
    func publishRecoveryFailure() async {
        guard let session = try? repository.activeSession(), let failure = session.error else { return }
        _ = try? await XPCClient.root(RootRequest(.recordRecoveryFailure, sessionID: session.id,
            recoveryAttempts: session.recoveryAttempts, recoveryRetryAt: session.recoveryDueAt, recoveryError: failure))
    }
    func reconcileRootRecovery() async throws {
        let lock = try CrossProcessLock(url: repository.lockURL).acquire(); defer { lock.unlock() }
        guard var session = try repository.activeSession(),
              ProcessInspector.liveness(session.process, uid: getuid()) == .dead,
              !session.recoveryTerminal, let baseline = try repository.baseline() else { return }
        // Claim through the serial root queue before inspecting fields. The authenticated agent
        // process then owns recovery; root only takes over after that process also dies.
        let receipt = try await XPCClient.root(RootRequest(.claim, sessionID: session.id,
            baselineVersion: baseline.version, baselineTimeZone: baseline.settings.timeZone,
            expectedTimeZone: NativePreferences.actualTimeZone(), process: session.process,
            automaticRecovery: true, recoveryAttempts: session.recoveryAttempts, recoveryOperation: true, recoveryRetryAt: session.recoveryDueAt))
        guard receipt.ownerUID == getuid(), receipt.ownerSessionID == session.id,
              receipt.baselineVersion == baseline.version else { throw CoreError(.ownershipConflict) }
        if receipt.restoredBaseline, (try? IdentifierNormalizer.timeZone(receipt.actualTimeZone)) == (try? IdentifierNormalizer.timeZone(baseline.settings.timeZone)),
           (try? IdentifierNormalizer.timeZone(NativePreferences.actualTimeZone())) == (try? IdentifierNormalizer.timeZone(receipt.actualTimeZone)) {
            session.lastKnownActual.timeZone = receipt.actualTimeZone
            session.timeZoneRecoveryReceipt = TimeZoneRecoveryReceipt(ownerUID: getuid(), sessionID: session.id,
                baselineVersion: baseline.version, timeZone: receipt.actualTimeZone)
            // Finish the root fallback's already-counted attempt rather than charging another.
            session.recoveryAttempts = max(session.recoveryAttempts, max(0, receipt.recoveryAttempts - 1))
        } else {
            session.recoveryAttempts = max(session.recoveryAttempts, receipt.recoveryAttempts)
            if let due = receipt.recoveryRetryAt, due > (session.recoveryDueAt ?? .distantPast) { session.recoveryDueAt = due }
        }
        try repository.saveSession(session)
    }
    func inspect(readActual: Bool = true) async {
        guard let own = ProcessInspector.identity(pid: getpid()) else { return }
        let executor = engine(process: own, automaticRecovery: true)
        do {
            try await reconcileRootRecovery()
            if let session = try repository.activeSession() {
                switch ProcessInspector.liveness(session.process, uid: getuid()) {
                case .dead:
                    guard !session.recoveryTerminal, session.recoveryAttempts < 3, session.recoveryDueAt.map({ Date() >= $0 }) ?? true else { return }
                    _ = try await runRecovery(process: own)
                case .alive: if readActual { _ = try await executor.inspectActual() }
                case .unknown:
                    let lock = try CrossProcessLock(url: repository.lockURL).acquire(); defer { lock.unlock() }
                    if var stopped = try repository.activeSession(), stopped.id == session.id,
                       ProcessInspector.liveness(stopped.process, uid: getuid()) == .unknown {
                        stopped.state = .needsAttention; stopped.recoveryTerminal = true
                        stopped.error = CoreError(.protectionUnavailable); try repository.saveSession(stopped)
                    }
                }
            }
        } catch { log.notice("Recovery remains pending: \(error.localizedDescription, privacy: .public)") }
    }
}
final class UserEndpoint: NSObject, UserServiceProtocol {
    let coordinator: UserCoordinator
    let process: ProcessIdentity
    init(coordinator: UserCoordinator, process: ProcessIdentity) { self.coordinator = coordinator; self.process = process }
    func perform(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        Task {
            let response: UserReply
            do {
                guard data.count <= 262_144 else { throw CoreError(.invalidTarget) }
                response = await coordinator.perform(try JSONDecoder().decode(UserRequest.self, from: data), process: process)
            } catch { response = UserReply(error: error as? CoreError ?? CoreError(.invalidTarget)) }
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
}
final class UserListener: NSObject, NSXPCListenerDelegate {
    let listener = NSXPCListener(machServiceName: RuntimePaths.agentID)
    let coordinator: UserCoordinator
    var monitor: Timer?
    var lifecycleTimer: Timer?
    var tokens: [NSObjectProtocol] = []
    init(coordinator: UserCoordinator, requirement: String) {
        self.coordinator = coordinator; super.init()
        listener.setConnectionCodeSigningRequirement(requirement); listener.delegate = self
        monitor = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in Task { await coordinator.inspect() } }
        // Process liveness has no heartbeat expiry: a sleeping or busy process remains alive.
        lifecycleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { await coordinator.inspect(readActual: false) } }
        tokens.append(NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { _ in Task { await coordinator.inspect() } })
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in Task { await coordinator.inspect() } })
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid(),
              PeerTrust.acceptsPeer(pid: connection.processIdentifier, uid: connection.effectiveUserIdentifier, executables: ["LocaleShift"]),
              let process = ProcessInspector.identity(pid: connection.processIdentifier) else { return false }
        connection.exportedInterface = NSXPCInterface(with: UserServiceProtocol.self)
        connection.exportedObject = UserEndpoint(coordinator: coordinator, process: process)
        connection.activate(); return true
    }
}

if CommandLine.arguments.contains("--diagnostics") {
    let state = try NativePreferences.read()
    let result: [String: Any] = ["role": "user-agent", "protocolVersion": RuntimePaths.protocolVersion,
        "actual": try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)),
        "trustedSignature": PeerTrust.canModifySystem, "systemWritesPerformed": false]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)); exit(0)
}
do {
    guard let requirement = PeerTrust.requirement(for: RuntimePaths.appID, executable: "LocaleShift", privileged: false) else { throw CoreError(.permissionDenied) }
    let coordinator = UserCoordinator(repository: try Repository(directory: RuntimePaths.userData))
    let server = UserListener(coordinator: coordinator, requirement: requirement)
    server.listener.activate(); Task { await coordinator.inspect() }
    RunLoop.main.run(); withExtendedLifetime(server) {}
} catch {
    log.error("User recovery service could not start: \(error.localizedDescription, privacy: .public)"); exit(78)
}
