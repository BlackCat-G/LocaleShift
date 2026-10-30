import Foundation
import Darwin

/// All system mutations enter here. The process lock remains held across adapter awaits;
/// actor reentrancy and another process therefore cannot start a second mutation.
public actor SwitchEngine {
    public let repository: Repository
    private let adapter: any SystemSettingsAdapter
    private let process: ProcessIdentity
    private let ownerUID: UInt32
    private let clock: @Sendable () -> Date
    public let capabilities: EngineCapabilities
    public init(repository: Repository, adapter: any SystemSettingsAdapter, process: ProcessIdentity, capabilities: EngineCapabilities = EngineCapabilities(), ownerUID: UInt32 = UInt32(getuid()), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.repository = repository; self.adapter = adapter; self.process = process; self.capabilities = capabilities; self.ownerUID = ownerUID; self.clock = clock
    }
    private func classified(_ error: Error) -> CoreError {
        if let error = error as? CoreError { return error }
        return CoreError(.transientUnavailable, detail: error.localizedDescription)
    }
    public func status() async -> EngineStatus {
        var actual: SystemSettings?, baseline: DefaultBaseline?, session: WorkSession?, profiles: [WorkProfile] = [], preparation = TimezonePreparation(), failure: CoreError?, hasUnresolved = false, recoveryBackup: RecoverySnapshotEvidence?
        do { baseline = try repository.baseline(); profiles = try repository.profiles(); preparation = try repository.timezonePreparation(); actual = try await inspectActual(); session = try repository.activeSession(); hasUnresolved = try repository.operations().contains { $0.completedAt == nil }; preparation = try repository.timezonePreparation() }
        catch {
            failure = classified(error); session = try? repository.activeSession()
            if failure?.code == .dataCorrupt {
                actual = try? await adapter.read()
                recoveryBackup = try? repository.verifiedRecoverySnapshot()
                if baseline == nil { baseline = recoveryBackup?.baseline }
                hasUnresolved = true
            }
        }
        return EngineStatus(actual: actual, baseline: baseline, session: session, preparation: preparation, protection: await adapter.checkProtection(), capabilities: capabilities, profiles: profiles, error: failure, hasUnresolvedOperations: hasUnresolved, recoveryBackup: recoveryBackup)
    }
    public func preview(profile: WorkProfile) async throws -> SwitchPreview {
        let actual = try await inspectActual()
        return SwitchPreview(actual: actual, target: try profile.applying(to: actual), title: profile.title)
    }
    public func restorePreview() async throws -> SwitchPreview {
        guard let baseline = try repository.baseline() else { throw CoreError(.baselineMissing) }
        return SwitchPreview(actual: try await inspectActual(), target: baseline.settings, title: "系统默认配置")
    }
    public func confirmTimezonePreparation() async throws {
        let lease = try CrossProcessLock(url: repository.lockURL).acquire(); defer { lease.unlock() }
        guard try repository.baseline() != nil else { throw CoreError(.baselineMissing) }
        try repository.saveTimezonePreparation(TimezonePreparation(userConfirmed: true, confirmedAt: Date()))
    }
    @discardableResult public func updateBaseline(settings: SystemSettings, source: String) async throws -> DefaultBaseline {
        try repository.saveBaseline(settings: settings, source: source)
    }
    /// Read-only adapter access; a detected drift is persisted under the same mutation lock.
    @discardableResult public func inspectActual() async throws -> SystemSettings {
        let actual = try await adapter.read()
        if let session = try repository.activeSession(), session.ownerUID != ownerUID { throw CoreError(.ownershipConflict) }
        if let session = try repository.activeSession(), session.state == .working, !actual.matches(session.lastKnownActual) {
            let lease = try CrossProcessLock(url: repository.lockURL).acquire(); defer { lease.unlock() }
            // A switch may have committed after the first read. Compare only a fresh read under the lock.
            let currentActual = try await adapter.read()
            if var current = try repository.activeSession(), current.state == .working, !currentActual.matches(current.lastKnownActual) {
                current.state = .needsAttention; current.error = CoreError(.externalChange); current.recoveryTerminal = true
                try repository.saveSession(current)
                try repository.saveTimezonePreparation(TimezonePreparation())
            }
            return currentActual
        }
        return actual
    }
    private func checkedBaseline() throws -> DefaultBaseline {
        if let session = try repository.activeSession(), session.ownerUID != ownerUID { throw CoreError(.ownershipConflict) }
        guard let baseline = try repository.baseline() else { throw CoreError(.baselineMissing) }
        return baseline
    }
    @discardableResult public func apply(profile: WorkProfile, confirmedActual: SystemSettings) async throws -> OperationRecord {
        let lease = try CrossProcessLock(url: repository.lockURL).acquire(); defer { lease.unlock() }
        let baseline = try checkedBaseline()
        guard capabilities.canApply else { throw CoreError(.capabilityUnavailable) }
        guard try repository.timezonePreparation().userConfirmed else { throw CoreError(.preparationRequired) }
        guard await adapter.checkProtection().available else { throw CoreError(.protectionUnavailable) }
        let oldSession = try repository.activeSession()
        guard oldSession == nil || oldSession?.state == .working else { throw CoreError(.sessionUnresolved) }
        guard try repository.operations().allSatisfy({ $0.completedAt != nil }) else { throw CoreError(.sessionUnresolved) }
        let actual = try await adapter.read()
        guard actual.matches(confirmedActual) else { throw CoreError(.previewChanged) }
        if let oldSession, !actual.matches(oldSession.lastKnownActual) {
            try pauseForExternalChange(oldSession)
            throw CoreError(.externalChange)
        }
        let target = try profile.applying(to: actual)
        var session = oldSession ?? WorkSession(baselineVersion: baseline.version, process: process, target: target, targetTitle: profile.title, lastKnownActual: actual, ownerUID: ownerUID)
        session.process = process; session.timeZoneRecoveryReceipt = nil; session.target = target; session.targetTitle = profile.title; session.state = .working; session.error = nil
        let operation = OperationRecord(sessionID: session.id, baselineVersion: baseline.version, kind: .apply, title: profile.title, before: actual, target: target)
        let result = try await perform(operation: operation, session: session, oldSession: oldSession, automatic: false)
        if result.succeeded, var stored = try repository.profiles().first(where: { $0.id == profile.id }) { stored.lastAppliedAt = Date(); _ = try repository.saveProfile(stored) }
        return result
    }
    private func pauseForExternalChange(_ old: WorkSession) throws {
        var session = old; session.state = .needsAttention; session.error = CoreError(.externalChange); session.recoveryTerminal = true; session.recoveryDueAt = nil
        try repository.saveSession(session); try repository.saveTimezonePreparation(TimezonePreparation())
    }
    private func knownPath(_ actual: SystemSettings, session: WorkSession) throws -> Bool {
        let latest = try repository.operations().first { $0.sessionID == session.id && $0.completedAt == nil }
        var receiptProvesBaselineTimezone = false
        if let receipt = session.timeZoneRecoveryReceipt,
           receipt.ownerUID == session.ownerUID, receipt.sessionID == session.id, receipt.baselineVersion == session.baselineVersion,
           let baseline = try repository.baseline(), baseline.version == session.baselineVersion,
           let receiptZone = try? IdentifierNormalizer.timeZone(receipt.timeZone),
           receiptZone == (try? IdentifierNormalizer.timeZone(baseline.settings.timeZone)), actual.matches(baseline.settings, field: .timeZone) {
            receiptProvesBaselineTimezone = true
        }
        return SettingField.allCases.allSatisfy { field in
            if field == .timeZone && receiptProvesBaselineTimezone { return true }
            guard let operation = latest else { return actual.matches(session.lastKnownActual, field: field) }
            guard let step = operation.steps.first(where: { $0.field == field }) else { return false }
            switch step.state {
            case .pending, .rolledBack:
                return actual.matches(operation.before, field: field)
            case .intentSaved, .rollbackIntentSaved:
                return actual.matches(operation.before, field: field) || actual.matches(operation.target, field: field)
            case .verified:
                return actual.matches(operation.target, field: field) || actual.matches(session.lastKnownActual, field: field)
            case .failed:
                guard step.error?.code != .externalChange else { return false }
                if step.lastWriteIntent == .intentSaved || step.lastWriteIntent == .rollbackIntentSaved {
                    return actual.matches(operation.before, field: field) || actual.matches(operation.target, field: field)
                }
                return step.readback.map { actual.matches($0, field: field) && $0.matches(operation.before, field: field) } ?? false
            }
        }
    }
    /// A non-nil confirmedActual authorizes overwriting the freshly displayed external values.
    /// A stale confirmation still fails before writing anything.
    @discardableResult public func restore(confirmedActual: SystemSettings? = nil) async throws -> OperationRecord {
        let lease = try CrossProcessLock(url: repository.lockURL).acquire(); defer { lease.unlock() }
        let baseline = try checkedBaseline()
        let actual = try await adapter.read()
        if let confirmedActual, !actual.matches(confirmedActual) { throw CoreError(.previewChanged) }
        let oldSession = try repository.activeSession()
        if let oldSession, confirmedActual == nil, (try oldSession.error?.code == .externalChange || !knownPath(actual, session: oldSession)) {
            try pauseForExternalChange(oldSession); throw CoreError(.externalChange)
        }
        var session = oldSession ?? WorkSession(baselineVersion: baseline.version, process: process, target: baseline.settings, targetTitle: "系统默认配置", lastKnownActual: actual, ownerUID: ownerUID)
        session.state = .recovering; session.error = nil
        var operation = OperationRecord(sessionID: session.id, baselineVersion: baseline.version, kind: .restore, title: "恢复系统默认", before: actual, target: baseline.settings)
        operation.relatedOperationID = try repository.operations().first { $0.sessionID == session.id && $0.error != nil }?.id
        return try await perform(operation: operation, session: session, oldSession: oldSession, automatic: false)
    }
    /// The macOS lifecycle layer must establish process death/boot policy before calling this.
    /// Neither a PID nor heartbeat timeout alone is sufficient evidence of process death.
    @discardableResult public func recover(now: Date = Date()) async throws -> OperationRecord {
        let lease = try CrossProcessLock(url: repository.lockURL).acquire(); defer { lease.unlock() }
        guard var session = try repository.activeSession() else { throw CoreError(.sessionUnresolved, detail: "没有待恢复的工作会话。") }
        guard session.ownerUID == ownerUID else { throw CoreError(.ownershipConflict) }
        if session.recoveryAttempts >= 3 { throw CoreError(.recoveryExhausted) }
        if session.recoveryTerminal { throw session.error ?? CoreError(.sessionUnresolved) }
        if let due = session.recoveryDueAt, now < due { throw CoreError(.recoveryNotDue) }
        session.recoveryAttempts += 1
        session.recoveryDueAt = session.recoveryAttempts < 3 ? now.addingTimeInterval(session.recoveryAttempts == 1 ? 5 : 30) : nil
        session.state = .recovering
        // Persist attempt before any read/write or ownership request; a crashed attempt counts.
        try repository.saveSession(session)
        do {
            let baseline = try checkedBaseline()
            let actual = try await adapter.read()
            guard try knownPath(actual, session: session) else { try pauseForExternalChange(session); throw CoreError(.externalChange) }
            var operation = OperationRecord(sessionID: session.id, baselineVersion: baseline.version, kind: .recovery, title: "异常恢复系统默认", before: actual, target: baseline.settings, createdAt: now)
            operation.relatedOperationID = try repository.operations().first { $0.sessionID == session.id }?.id
            return try await perform(operation: operation, session: session, oldSession: session, automatic: true, now: now)
        } catch {
            let failure = classified(error)
            if var current = try repository.activeSession() {
                scheduleFailure(&current, failure: failure, automatic: true, now: now)
                try repository.saveSession(current)
            }
            throw failure
        }
    }
    private func scheduleFailure(_ session: inout WorkSession, failure: CoreError, automatic: Bool, now: Date) {
        session.state = .needsAttention; session.error = failure
        session.recoveryTerminal = failure.code.isTerminalRecovery || (automatic && session.recoveryAttempts >= 3)
        if automatic && !session.recoveryTerminal { session.recoveryDueAt = max(now, clock()).addingTimeInterval(session.recoveryAttempts == 1 ? 5 : 30) }
        else { session.recoveryDueAt = nil }
    }
    private func requireCapability(_ field: SettingField) throws {
        let allowed: Bool
        switch field { case .languages: allowed = capabilities.languageWrite; case .region: allowed = capabilities.regionWrite; case .timeZone: allowed = capabilities.timeZoneWrite }
        guard allowed else { throw CoreError(.capabilityUnavailable, field: field) }
    }
    private func perform(operation initial: OperationRecord, session initialSession: WorkSession, oldSession: WorkSession?, automatic: Bool, now: Date = Date()) async throws -> OperationRecord {
        var operation = initial, session = initialSession, expected = initial.before
        try repository.commit(operation: operation, session: session)
        do {
            try await adapter.beginOwnership(sessionID: session.id, baselineVersion: session.baselineVersion, process: session.process)
            operation.state = .executing; try repository.commit(operation: operation, session: session)
            for index in operation.steps.indices {
                let field = operation.steps[index].field
                if expected.matches(operation.target, field: field) {
                    operation.steps[index].state = .verified; operation.steps[index].readback = expected
                    try repository.commit(operation: operation, session: session); continue
                }
                try requireCapability(field)
                if operation.kind == .apply, !(await adapter.checkProtection().available) { throw CoreError(.protectionUnavailable) }
                if field == .timeZone { session.timeZoneRecoveryReceipt = nil }
                operation.steps[index].state = .intentSaved; operation.steps[index].lastWriteIntent = .intentSaved
                try repository.commit(operation: operation, session: session)
                let beforeWrite = try await adapter.read()
                guard beforeWrite.matches(expected) else { throw CoreError(.externalChange, field: field) }
                try await adapter.write(field: field, settings: operation.target, operationID: operation.id, sessionID: session.id)
                operation.state = .verifying
                let actual = try await adapter.read()
                expected.copy(field, from: operation.target)
                operation.steps[index].readback = actual
                guard actual.matches(expected) else { throw CoreError(actual.matches(operation.target, field: field) ? .externalChange : .readbackMismatch, field: field) }
                operation.steps[index].state = .verified; session.lastKnownActual = actual
                operation.state = .executing; try repository.commit(operation: operation, session: session)
            }
            let actual = try await adapter.read()
            guard actual.matches(operation.target) else { throw CoreError(.readbackMismatch) }
            operation.state = .completed; operation.completedAt = Date(); session.lastKnownActual = actual; session.error = nil
            if operation.kind == .apply {
                session.state = .working; try repository.commit(operation: operation, session: session)
            } else {
                // Keep recovery duty durable until the machine-level owner was released successfully.
                try await adapter.release(sessionID: session.id)
                try repository.completeRecovery(operation: operation)
            }
            return operation
        } catch {
            var failure = classified(error)
            operation.error = failure; operation.state = .rollingBack; operation.completedAt = nil
            if let index = operation.steps.firstIndex(where: { $0.state == .intentSaved }) { operation.steps[index].error = failure }
            try repository.commit(operation: operation, session: session)
            var rollbackSucceeded = true
            // A permission rejection must never trigger another authorization through compensation.
            if failure.code == .permissionDenied || failure.code == .ownershipConflict || failure.code == .dataCorrupt { rollbackSucceeded = false }
            else {
                for index in operation.steps.indices.reversed() {
                    let field = operation.steps[index].field
                    guard operation.steps[index].state == .verified || operation.steps[index].state == .intentSaved else { continue }
                    do {
                        let actual = try await adapter.read()
                        if actual.matches(operation.before, field: field) { operation.steps[index].state = .rolledBack; continue }
                        guard actual.matches(operation.target, field: field) else { throw CoreError(.externalChange, field: field) }
                        operation.steps[index].state = .rollbackIntentSaved; operation.steps[index].lastWriteIntent = .rollbackIntentSaved; try repository.commit(operation: operation, session: session)
                        try await adapter.write(field: field, settings: operation.before, operationID: operation.id, sessionID: session.id)
                        let readback = try await adapter.read(); operation.steps[index].readback = readback
                        guard readback.matches(operation.before, field: field) else { throw CoreError(.readbackMismatch, field: field) }
                        operation.steps[index].state = .rolledBack
                        session.lastKnownActual.copy(field, from: operation.before)
                        try repository.commit(operation: operation, session: session)
                    } catch {
                        let compensationError = classified(error); operation.steps[index].error = compensationError; operation.steps[index].state = .failed
                        if compensationError.code.isTerminalRecovery { failure = compensationError }
                        rollbackSucceeded = false
                        if compensationError.code == .permissionDenied || compensationError.code == .ownershipConflict { break }
                    }
                }
                do { let actual = try await adapter.read(); if !actual.matches(operation.before) { rollbackSucceeded = false; failure = CoreError(.externalChange) } } catch { rollbackSucceeded = false }
            }
            operation.error = failure
            if failure.code == .externalChange { try repository.saveTimezonePreparation(TimezonePreparation()) }
            if rollbackSucceeded && operation.kind == .apply {
                operation.state = .rolledBack; operation.completedAt = Date()
                if var original = oldSession { original.lastKnownActual = operation.before; try repository.commit(operation: operation, session: original) }
                else {
                    do { try await adapter.release(sessionID: session.id); try repository.commit(operation: operation, session: nil) }
                    catch { operation.state = .needsAttention; operation.completedAt = nil; scheduleFailure(&session, failure: classified(error), automatic: automatic, now: now); try repository.commit(operation: operation, session: session) }
                }
            } else {
                operation.state = .needsAttention; operation.completedAt = nil
                scheduleFailure(&session, failure: failure, automatic: automatic, now: now)
                try repository.commit(operation: operation, session: session)
            }
            return operation
        }
    }
}
