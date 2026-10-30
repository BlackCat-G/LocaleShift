import Foundation
import CryptoKit
import Darwin
import LocaleShiftCore

private struct Lease: Codable {
    var uid: UInt32
    var sessionID: UUID
    var baselineVersion: UUID
    var baselineTimeZone: String
    var lastTimeZone: String
    var process: ProcessIdentity
    var userExecutor: ProcessIdentity?
    var restoredBaseline = false
    var phase: String = "owned"
    var operationID: UUID?
    var intentBefore: String?
    var intentTarget: String?
    var attempts: Int = 0
    var retryAt: Date?
    var error: CoreError?
}
private struct MachineJournal: Codable { var version = 1; var lease: Lease? }
private struct MachineEnvelope: Codable { var data: Data; var sha256: String }

/// All methods are invoked on the daemon's single serial queue.
public final class MachineLeaseStore {
    private let directory: URL
    private let journalURL: URL
    private var state: MachineJournal
    private var storageError: CoreError?
    public init(directory: URL = RuntimePaths.machineData) throws {
        guard geteuid() == 0 else { throw CoreError(.permissionDenied) }
        self.directory = directory; journalURL = directory.appendingPathComponent("machine-journal.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0, metadata.st_uid == 0,
              metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o022 == 0 else {
            throw CoreError(.dataCorrupt, detail: "系统恢复目录的权限不可靠。")
        }
        state = MachineJournal()
        if FileManager.default.fileExists(atPath: journalURL.path) {
            do {
                var journalMetadata = stat()
                guard lstat(journalURL.path, &journalMetadata) == 0, journalMetadata.st_uid == 0,
                      journalMetadata.st_mode & S_IFMT == S_IFREG, journalMetadata.st_mode & 0o077 == 0 else { throw CoreError(.dataCorrupt) }
                let envelope = try JSONDecoder().decode(MachineEnvelope.self, from: Data(contentsOf: journalURL))
                guard envelope.sha256 == Self.hash(envelope.data) else { throw CoreError(.dataCorrupt) }
                state = try JSONDecoder().decode(MachineJournal.self, from: envelope.data)
                guard state.version == 1 else { throw CoreError(.dataCorrupt) }
            } catch { storageError = CoreError(.dataCorrupt, detail: "系统时区恢复记录无法核验。") }
        }
    }
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func save() throws {
        do { try persist() }
        catch {
            let failure = error as? CoreError ?? CoreError(.persistence)
            storageError = failure; throw failure
        }
    }
    private func persist() throws {
        if let error = storageError { throw error }
        let content = try JSONEncoder().encode(state)
        let envelope = MachineEnvelope(data: content, sha256: Self.hash(content))
        let bytes = try JSONEncoder().encode(envelope)
        let temporary = directory.appendingPathComponent(".journal-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CoreError(.persistence) }
        defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { throw CoreError(.persistence) }
                offset += written
            }
        }
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0,
              rename(temporary.path, journalURL.path) == 0 else { throw CoreError(.persistence) }
        let dirFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard dirFD >= 0 else { throw CoreError(.persistence) }
        defer { close(dirFD) }
        guard fsync(dirFD) == 0, (try? Data(contentsOf: journalURL)) == bytes else { throw CoreError(.persistence, detail: "系统恢复记录写后校验失败。") }
    }
    private func zone(_ identifier: String) throws -> String {
        let value = try IdentifierNormalizer.timeZone(identifier)
        guard Set(TimeZone.knownTimeZoneIdentifiers).contains(value) else { throw CoreError(.invalidTarget, field: .timeZone) }
        return value
    }
    private func actualZone() -> String { NativePreferences.actualTimeZone() }
    private func reply(error: CoreError? = nil) -> RootReply {
        RootReply(available: storageError == nil && error == nil, actualTimeZone: actualZone(),
            ownerUID: state.lease?.uid, ownerSessionID: state.lease?.sessionID, error: error ?? storageError, restoredBaseline: state.lease?.restoredBaseline == true, baselineVersion: state.lease?.baselineVersion, recoveryAttempts: state.lease?.attempts ?? 0, recoveryRetryAt: state.lease?.retryAt)
    }
    public func perform(_ request: RootRequest, callerUID: UInt32, callerProcess: ProcessIdentity) -> RootReply {
        do {
            if let error = storageError { throw error }
            guard request.version == RuntimePaths.protocolVersion else { throw CoreError(.capabilityUnavailable) }
            if request.action == .status {
                if let owner = state.lease, owner.uid != callerUID { throw CoreError(.ownershipConflict) }
                return reply(error: state.lease?.error)
            }
            guard let sessionID = request.sessionID else { throw CoreError(.invalidTarget) }
            switch request.action {
            case .status: break
            case .claim:
                guard let baseline = request.baselineTimeZone, let expected = request.expectedTimeZone,
                      let version = request.baselineVersion, let process = request.process else { throw CoreError(.permissionDenied) }
                let base = try zone(baseline), before = try zone(expected)
                guard try zone(actualZone()) == before else { throw CoreError(.previewChanged) }
                if let existing = state.lease {
                    if request.automaticRecovery, existing.phase == "needsAttention" { throw existing.error ?? CoreError(.recoveryExhausted) }
                    if request.automaticRecovery, let error = existing.error, error.code.isTerminalRecovery { throw error }
                    if request.automaticRecovery, existing.attempts >= 3, !existing.restoredBaseline { throw CoreError(.recoveryExhausted) }
                    guard existing.uid == callerUID, existing.sessionID == sessionID,
                          existing.baselineVersion == version, existing.baselineTimeZone == base else { throw CoreError(.ownershipConflict) }
                    guard request.confirmedExternalChange || [existing.lastTimeZone, existing.baselineTimeZone, existing.intentBefore, existing.intentTarget].compactMap({ $0 }).contains(before) else {
                        throw CoreError(.externalChange)
                    }
                    if existing.process != process {
                        guard ProcessInspector.identity(pid: process.pid, uid: callerUID) == process else { throw CoreError(.permissionDenied) }
                        state.lease?.process = process
                    }
                } else {
                    guard ProcessInspector.identity(pid: process.pid, uid: callerUID) == process ||
                          (request.recoveryOperation && ProcessInspector.identity(pid: callerProcess.pid, uid: callerUID) == callerProcess) else { throw CoreError(.permissionDenied) }
                    state.lease = Lease(uid: callerUID, sessionID: sessionID, baselineVersion: version,
                        baselineTimeZone: base, lastTimeZone: before, process: process)
                }
                state.lease?.userExecutor = callerProcess
                if request.automaticRecovery {
                    let count = max(state.lease?.attempts ?? 0, min(request.recoveryAttempts, 3))
                    state.lease?.attempts = count
                    if let due = request.recoveryRetryAt, due > (state.lease?.retryAt ?? .distantPast) { state.lease?.retryAt = due }
                }
                try save()
            case .write:
                guard var owner = state.lease, owner.uid == callerUID, owner.sessionID == sessionID,
                      let requested = request.targetTimeZone, let expected = request.expectedTimeZone else { throw CoreError(.ownershipConflict) }
                if request.automaticRecovery, let error = owner.error, error.code.isTerminalRecovery { throw error }
                if request.automaticRecovery {
                    guard request.recoveryAttempts > 0, request.recoveryAttempts <= 3, owner.attempts <= request.recoveryAttempts else { throw CoreError(.recoveryExhausted) }
                    owner.attempts = max(owner.attempts, request.recoveryAttempts)
                }
                let target = try zone(requested), before = try zone(expected), actual = try zone(actualZone())
                guard actual == before else { throw CoreError(.previewChanged) }
                guard request.confirmedExternalChange || [owner.lastTimeZone, owner.baselineTimeZone, owner.intentBefore, owner.intentTarget].compactMap({ $0 }).contains(actual) else {
                    throw CoreError(.externalChange, field: .timeZone)
                }
                owner.operationID = request.operationID
                owner.intentBefore = actual; owner.intentTarget = target; owner.phase = "writing"
                state.lease = owner; try save()
                if actual != target { try setZone(target) }
                owner.lastTimeZone = target; owner.intentBefore = nil; owner.intentTarget = nil; owner.phase = "owned"
                owner.error = nil; owner.restoredBaseline = target == owner.baselineTimeZone
                if !request.automaticRecovery { owner.attempts = 0; owner.retryAt = nil }
                state.lease = owner; try save()
            case .recordRecoveryFailure:
                guard var owner = state.lease, owner.uid == callerUID, owner.sessionID == sessionID,
                      let failure = request.recoveryError else { throw CoreError(.ownershipConflict) }
                owner.attempts = max(owner.attempts, min(request.recoveryAttempts, 3)); owner.error = failure
                owner.retryAt = request.recoveryRetryAt
                if failure.code.isTerminalRecovery || owner.attempts >= 3 { owner.phase = "needsAttention"; owner.retryAt = nil }
                state.lease = owner; try save()
            case .pauseRecovery:
                guard var owner = state.lease else { return reply() }
                guard owner.uid == callerUID, owner.sessionID == sessionID else { throw CoreError(.ownershipConflict) }
                owner.phase = "needsAttention"; owner.error = CoreError(.sessionUnresolved, detail: "已由用户选择暂不恢复。")
                owner.retryAt = nil; state.lease = owner; try save()
            case .release:
                if let owner = state.lease {
                    guard owner.uid == callerUID, owner.sessionID == sessionID else { throw CoreError(.ownershipConflict) }
                    guard try zone(actualZone()) == owner.baselineTimeZone else { throw CoreError(.readbackMismatch, field: .timeZone) }
                    state.lease = nil; try save()
                }
            }
            return reply()
        } catch {
            let failure = error as? CoreError ?? CoreError(.transientUnavailable, detail: error.localizedDescription)
            if request.automaticRecovery, var owner = state.lease, owner.uid == callerUID, owner.sessionID == request.sessionID {
                owner.error = failure
                if failure.code.isTerminalRecovery || owner.attempts >= 3 { owner.phase = "needsAttention"; owner.retryAt = nil }
                else if failure.code != .recoveryNotDue { owner.retryAt = Date().addingTimeInterval(owner.attempts <= 1 ? 5 : 30) }
                state.lease = owner; try? save()
            }
            return reply(error: failure)
        }
    }
    public func monitor(now: Date = Date()) {
        guard storageError == nil, var owner = state.lease, owner.phase != "restored", owner.phase != "needsAttention" else { return }
        // User service owns normal recovery. Root is the fallback only after both writers are dead.
        if let executor = owner.userExecutor {
            let executorLife = ProcessInspector.liveness(executor, uid: owner.uid)
            if executorLife == .alive { return }
            if executorLife == .unknown { return } // Unknown never proves death.
        }
        let life = ProcessInspector.liveness(owner.process, uid: owner.uid)
        guard life != .alive else { return }
        if life == .unknown {
            owner.phase = "needsAttention"; owner.error = CoreError(.protectionUnavailable, detail: "无法核验原应用进程，请手动确认恢复。")
            state.lease = owner; try? save(); return
        }
        guard owner.attempts < 3, owner.retryAt.map({ now >= $0 }) ?? true else { return }
        do {
            let actual = try zone(actualZone())
            guard [owner.lastTimeZone, owner.baselineTimeZone, owner.intentBefore, owner.intentTarget].compactMap({ $0 }).contains(actual) else { throw CoreError(.externalChange) }
            owner.attempts += 1; owner.retryAt = owner.attempts < 3 ? now.addingTimeInterval(owner.attempts == 1 ? 5 : 30) : nil; owner.phase = "recovering"; owner.intentBefore = actual
            owner.intentTarget = owner.baselineTimeZone; state.lease = owner; try save()
            if actual != owner.baselineTimeZone { try setZone(owner.baselineTimeZone) }
            owner.lastTimeZone = owner.baselineTimeZone; owner.phase = "restored"
            owner.error = nil; owner.retryAt = nil; owner.restoredBaseline = true; state.lease = owner; try save()
        } catch {
            let failure = error as? CoreError ?? CoreError(.transientUnavailable)
            owner.error = failure
            if failure.code.isTerminalRecovery || owner.attempts >= 3 {
                owner.phase = "needsAttention"; owner.retryAt = nil
            } else { owner.retryAt = Date().addingTimeInterval(owner.attempts <= 1 ? 5 : 30) }
            state.lease = owner; try? save()
        }
    }
    private func setZone(_ target: String) throws {
        let process = Process(), pipe = Pipe()
        let outputBox = CommandOutput()
        let readers = DispatchGroup()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/systemsetup")
        process.arguments = ["-settimezone", try zone(target)]
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { throw CoreError(.permissionDenied, field: .timeZone) }
        readers.enter()
        DispatchQueue.global().async {
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty { outputBox.append(chunk) }
            readers.leave()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate(); Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try? pipe.fileHandleForWriting.close()
        guard readers.wait(timeout: .now() + 2) == .success else { throw CoreError(.transientUnavailable, field: .timeZone) }
        let output = String(decoding: outputBox.data, as: UTF8.self).lowercased()
        let actual = actualZone()
        let link = try? FileManager.default.destinationOfSymbolicLink(atPath: "/etc/localtime")
        guard (try? zone(actual)) == target, let link,
              (try? zone(URL(fileURLWithPath: link).path.components(separatedBy: "/zoneinfo/").last ?? "")) == target else {
            if ["need administrator", "requires administrator", "not authorized", "permission", "authorization", "access denied"].contains(where: output.contains) {
                throw CoreError(.permissionDenied, field: .timeZone)
            }
            throw CoreError(.readbackMismatch, field: .timeZone)
        }
    }
}

private final class CommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; if bytes.count < 65_536 { bytes.append(data.prefix(65_536 - bytes.count)) } }
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
}
