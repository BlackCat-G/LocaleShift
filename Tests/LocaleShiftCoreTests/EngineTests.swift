import Foundation
import CSQLite
#if canImport(XCTest)
import XCTest
#else
import Testing
#endif
@testable import LocaleShiftCore

final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value = value.addingTimeInterval(seconds) }
}

actor MemoryAdapter: SystemSettingsAdapter {
    var actual: SystemSettings
    var protection = ProtectionStatus(available: true)
    var ownership: UUID?
    var ownershipIDs: [UUID] = []
    var writes: [SettingField] = []
    var failField: SettingField?
    var failCode: CoreErrorCode = .transientUnavailable
    var failOnce = false
    let repo: Repository
    var sawPersistedIntent = true
    var ownershipRecoveryDueAt: Date?
    var failReleaseOnce = false
    var readReplacement: WorkSession?
    var slowFailureClock: ManualClock?
    var slowFailureDuration: TimeInterval = 0
    init(_ actual: SystemSettings, repo: Repository) { self.actual = actual; self.repo = repo }
    func read() async throws -> SystemSettings {
        let result = actual
        if let replacement = readReplacement { readReplacement = nil; actual = replacement.lastKnownActual; try repo.saveSession(replacement) }
        return result
    }
    func replaceSessionAfterNextRead(_ session: WorkSession) { readReplacement = session }
    func slowFailure(clock: ManualClock, duration: TimeInterval) { slowFailureClock = clock; slowFailureDuration = duration }
    func checkProtection() async -> ProtectionStatus { protection }
    func beginOwnership(sessionID: UUID, baselineVersion: UUID, process: ProcessIdentity) async throws {
        if let ownership, ownership != sessionID { throw CoreError(.ownershipConflict) }
        ownership = sessionID; ownershipIDs.append(sessionID)
        ownershipRecoveryDueAt = try repo.activeSession()?.recoveryDueAt
    }
    func write(field: SettingField, settings: SystemSettings, operationID: UUID, sessionID: UUID) async throws {
        let operation = try repo.operations().first { $0.id == operationID }
        let step = operation?.steps.first { $0.field == field }
        sawPersistedIntent = sawPersistedIntent && operation != nil && operation?.completedAt == nil && (step?.state == .intentSaved || step?.state == .rollbackIntentSaved)
        if failField == field { slowFailureClock?.advance(slowFailureDuration); if failOnce { failField = nil }; throw CoreError(failCode, field: field) }
        writes.append(field); actual.copy(field, from: settings)
    }
    func release(sessionID: UUID) async throws { if failReleaseOnce { failReleaseOnce = false; throw CoreError(.transientUnavailable) }; if ownership == sessionID { ownership = nil } }
    func failNextRelease() { failReleaseOnce = true }
    func fail(_ field: SettingField?, code: CoreErrorCode = .transientUnavailable, once: Bool = false) { failField = field; failCode = code; failOnce = once }
    func changeExternally(_ value: SystemSettings) { actual = value }
    func setProtection(_ available: Bool) { protection.available = available }
}

final class EngineTests: CoreTestBase {
    let defaults = SystemSettings(languages: ["zh-CN", "en-US", "ja"], region: "zh_CN@calendar=gregorian;numbers=hanidec", timeZone: "Asia/Shanghai")
    let process = ProcessIdentity(pid: 200, startSeconds: 100, startMicroseconds: 1, bootID: "boot-a")
    let capabilities = EngineCapabilities(languageWrite: true, regionWrite: true, timeZoneWrite: true, backgroundRecovery: true)
    let ny = WorkProfile(language: "en-US", region: "en_US", timeZone: "America/New_York")
    let tokyo = WorkProfile(language: "ja", region: "ja_JP", timeZone: "Asia/Tokyo")
    func setup(prepared: Bool = true, clock: @escaping @Sendable () -> Date = { Date() }) async throws -> (Repository, MemoryAdapter, SwitchEngine) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let repo = try Repository(directory: directory)
        try repo.saveBaseline(settings: defaults, source: "test")
        let adapter = MemoryAdapter(defaults, repo: repo)
        let engine = SwitchEngine(repository: repo, adapter: adapter, process: process, capabilities: capabilities, clock: clock)
        if prepared { try await engine.confirmTimezonePreparation() }
        return (repo, adapter, engine)
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testContinuousSwitchesReuseSessionAndRestoreExactFixedBaseline() async throws {
        let (repo, adapter, engine) = try await setup()
        let first = try await engine.apply(profile: ny, confirmedActual: defaults)
        XCTAssertTrue(first.succeeded)
        let firstSession = try repo.activeSession()!
        let nyActual = try await adapter.read()
        XCTAssertEqual(nyActual.region, "en_US@calendar=gregorian;numbers=hanidec")
        let second = try await engine.apply(profile: tokyo, confirmedActual: nyActual)
        XCTAssertEqual(first.sessionID, second.sessionID)
        XCTAssertEqual(try repo.activeSession()?.id, firstSession.id)
        XCTAssertEqual(second.before, nyActual)
        XCTAssertEqual(try repo.baseline()?.settings, defaults)
        let restored = try await engine.restore()
        XCTAssertTrue(restored.succeeded)
        let actual = try await adapter.read()
        XCTAssertEqual(actual, defaults)
        XCTAssertNil(try repo.activeSession())
        let owner = await adapter.ownership
        XCTAssertNil(owner)
        let durable = await adapter.sawPersistedIntent
        XCTAssertTrue(durable)
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testPreviewChangeAndPreparationBlockAllWrites() async throws {
        let (_, adapter, engine) = try await setup(prepared: false)
        do { _ = try await engine.apply(profile: ny, confirmedActual: defaults); XCTFail("Must require preparation") } catch { XCTAssertEqual((error as? CoreError)?.code, .preparationRequired) }
        try await engine.confirmTimezonePreparation()
        var drift = defaults; drift.region = "en_GB"
        await adapter.changeExternally(drift)
        do { _ = try await engine.apply(profile: ny, confirmedActual: defaults); XCTFail("Must refresh preview") } catch { XCTAssertEqual((error as? CoreError)?.code, .previewChanged) }
        let writes = await adapter.writes
        XCTAssertEqual(writes, [])
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testFailedContinuousSwitchRollsBackBeforeSnapshotNotBaseline() async throws {
        let (repo, adapter, engine) = try await setup()
        _ = try await engine.apply(profile: ny, confirmedActual: defaults)
        let before = try await adapter.read()
        await adapter.fail(.timeZone, once: true)
        let failed = try await engine.apply(profile: tokyo, confirmedActual: before)
        XCTAssertEqual(failed.state, .rolledBack)
        let actual = try await adapter.read()
        XCTAssertEqual(actual, before)
        XCTAssertEqual(try repo.activeSession()?.target, before)
        let restore = try await engine.restore()
        XCTAssertTrue(restore.succeeded)
        let final = try await adapter.read()
        XCTAssertEqual(final, defaults)
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testExternalDriftStopsAutomaticRecoveryThenFreshUserConfirmationCanRestore() async throws {
        let (repo, adapter, engine) = try await setup()
        _ = try await engine.apply(profile: ny, confirmedActual: defaults)
        var drift = try await adapter.read(); drift.timeZone = "Europe/Paris"
        await adapter.changeExternally(drift)
        _ = try await engine.inspectActual()
        XCTAssertFalse(try repo.timezonePreparation().userConfirmed)
        do { _ = try await engine.recover(now: Date()); XCTFail("Must preserve external changes") } catch { XCTAssertEqual((error as? CoreError)?.code, .externalChange) }
        let untouched = try await adapter.read()
        XCTAssertEqual(untouched, drift)
        let restored = try await engine.restore(confirmedActual: drift)
        XCTAssertTrue(restored.succeeded)
        let actual = try await adapter.read()
        XCTAssertEqual(actual, defaults)
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testRecoveryRetryCountAndDueTimesSurviveNewEngine() async throws {
        let manualClock = ManualClock(Date(timeIntervalSince1970: 1000))
        let (repo, adapter, engine) = try await setup(clock: { manualClock.now() })
        _ = try await engine.apply(profile: ny, confirmedActual: defaults)
        await adapter.fail(.languages)
        let now = Date(timeIntervalSince1970: 1000)
        let first = try await engine.recover(now: now)
        XCTAssertFalse(first.succeeded)
        XCTAssertEqual(try repo.activeSession()?.recoveryAttempts, 1)
        let reservedDue = await adapter.ownershipRecoveryDueAt
        XCTAssertEqual(reservedDue, now.addingTimeInterval(5))
        XCTAssertEqual(try repo.activeSession()?.recoveryDueAt, now.addingTimeInterval(5))
        let reopened = try Repository(directory: repo.directory)
        let next = SwitchEngine(repository: reopened, adapter: adapter, process: process, capabilities: capabilities, clock: { manualClock.now() })
        do { _ = try await next.recover(now: now.addingTimeInterval(4)); XCTFail("Must honor persisted due time") } catch { XCTAssertEqual((error as? CoreError)?.code, .recoveryNotDue) }
        _ = try await next.recover(now: now.addingTimeInterval(5))
        XCTAssertEqual(try reopened.activeSession()?.recoveryAttempts, 2)
        XCTAssertEqual(try reopened.activeSession()?.recoveryDueAt, now.addingTimeInterval(35))
        _ = try await next.recover(now: now.addingTimeInterval(35))
        XCTAssertEqual(try reopened.activeSession()?.recoveryAttempts, 3)
        XCTAssertTrue(try reopened.activeSession()!.recoveryTerminal)
        do { _ = try await next.recover(now: now.addingTimeInterval(100)); XCTFail("Maximum three attempts") } catch { XCTAssertEqual((error as? CoreError)?.code, .recoveryExhausted) }
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testDenialIsTerminalWithoutRepeatedAuthorizationAndManualRetryRetainsHistory() async throws {
        let (repo, adapter, engine) = try await setup()
        _ = try await engine.apply(profile: ny, confirmedActual: defaults)
        await adapter.fail(.languages, code: .permissionDenied)
        let denied = try await engine.recover(now: Date())
        XCTAssertEqual(denied.error?.code, .permissionDenied)
        XCTAssertTrue(try repo.activeSession()!.recoveryTerminal)
        do { _ = try await engine.recover(now: Date().addingTimeInterval(60)); XCTFail("Denial must stop automatic attempts") } catch { XCTAssertEqual((error as? CoreError)?.code, .permissionDenied) }
        await adapter.fail(nil)
        let fresh = try await adapter.read()
        let manual = try await engine.restore(confirmedActual: fresh)
        XCTAssertTrue(manual.succeeded)
        XCTAssertNotNil(try repo.operations().first { $0.id == denied.id }?.error)
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testInterruptedIntentMayAlreadyHaveWrittenAndRecoveryUsesRealValues() async throws {
        let (repo, adapter, engine) = try await setup()
        let baseline = try repo.baseline()!
        let target = try ny.applying(to: defaults)
        let session = WorkSession(baselineVersion: baseline.version, process: process, target: target, targetTitle: ny.title, lastKnownActual: defaults)
        var op = OperationRecord(sessionID: session.id, baselineVersion: baseline.version, kind: .apply, title: ny.title, before: defaults, target: target)
        op.state = .executing; op.steps[0].state = .intentSaved
        try repo.commit(operation: op, session: session)
        var partial = defaults; partial.languages = target.languages
        await adapter.changeExternally(partial)
        let recovered = try await engine.recover(now: Date())
        XCTAssertTrue(recovered.succeeded)
        XCTAssertNil(try repo.activeSession())
        let actual = try await adapter.read(); XCTAssertEqual(actual, defaults)
        XCTAssertEqual(try repo.operations().first { $0.id == op.id }?.state, .rolledBack)
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testRestartIntentRequiresProvenImmediateBootAndCannotBeConsumedTwice() throws {
        var intent = RestartIntent(sessionID: UUID(), baselineVersion: UUID(), sourceBootID: "a", expected: defaults, now: Date(timeIntervalSince1970: 1000))
        intent.normalRestartObserved = true
        XCTAssertThrowsError(try intent.consume(targetBootID: "b", targetBootTime: Date(timeIntervalSince1970: 1100), uptime: 10, provenImmediateNextBoot: false))
        try intent.consume(targetBootID: "b", targetBootTime: Date(timeIntervalSince1970: 1100), uptime: 10, provenImmediateNextBoot: true)
        XCTAssertTrue(intent.canConnect(bootID: "b", uptime: 69))
        XCTAssertFalse(intent.canConnect(bootID: "b", uptime: 71))
        XCTAssertFalse(intent.canConnect(bootID: "c", uptime: 20))
        XCTAssertThrowsError(try intent.consume(targetBootID: "c", targetBootTime: Date(timeIntervalSince1970: 1150), uptime: 1, provenImmediateNextBoot: true))
        XCTAssertEqual(intent.handoffDeadlineUptime, 70)
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testTargetWithoutPersistedFieldIntentIsNotAnAuthorizedRecoveryPath() async throws {
        let (repo, adapter, engine) = try await setup()
        let baseline = try repo.baseline()!
        let target = try ny.applying(to: defaults)
        let session = WorkSession(baselineVersion: baseline.version, process: process, target: target, targetTitle: ny.title, lastKnownActual: defaults)
        let operation = OperationRecord(sessionID: session.id, baselineVersion: baseline.version, kind: .apply, title: ny.title, before: defaults, target: target)
        try repo.commit(operation: operation, session: session)
        // No field intent was durable, so this cannot have been our write.
        await adapter.changeExternally(target)
        do { _ = try await engine.recover(); XCTFail("Must not overwrite unrecorded writes") } catch { XCTAssertEqual((error as? CoreError)?.code, .externalChange) }
        let actual = try await adapter.read(); XCTAssertEqual(actual, target)
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testCapabilityAndProtectionGateNewWorkBeforeSessionCreation() async throws {
        let (repo, adapter, engine) = try await setup()
        await adapter.setProtection(false)
        do { _ = try await engine.apply(profile: ny, confirmedActual: defaults); XCTFail("Must gate protection") } catch { XCTAssertEqual((error as? CoreError)?.code, .protectionUnavailable) }
        await adapter.setProtection(true)
        let readOnly = SwitchEngine(repository: repo, adapter: adapter, process: process)
        do { _ = try await readOnly.apply(profile: ny, confirmedActual: defaults); XCTFail("Must gate capabilities") } catch { XCTAssertEqual((error as? CoreError)?.code, .capabilityUnavailable) }
        XCTAssertNil(try repo.activeSession())
        XCTAssertEqual(try repo.operations().count, 0)
        let writes = await adapter.writes; XCTAssertEqual(writes, [])
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testOwnerReleaseFailureKeepsSessionAndRollbackIntentsUncompleted() async throws {
        let (repo, adapter, engine) = try await setup()
        _ = try await engine.apply(profile: ny, confirmedActual: defaults)
        await adapter.failNextRelease()
        let result = try await engine.restore()
        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.completedAt)
        XCTAssertNotNil(try repo.activeSession())
        let durable = await adapter.sawPersistedIntent
        XCTAssertTrue(durable)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testPersistedOwnerUIDPreventsCrossUserRecoveryOrRestartConsumption() async throws {
        let (repo, adapter, engine) = try await setup()
        _ = try await engine.apply(profile: ny, confirmedActual: defaults)
        let uid = UInt32(getuid())
        XCTAssertEqual(try repo.activeSession()?.ownerUID, uid)
        let other = SwitchEngine(repository: repo, adapter: adapter, process: process, capabilities: capabilities, ownerUID: uid + 1)
        do { _ = try await other.recover(); XCTFail("Cross-user recovery must stop") } catch { XCTAssertEqual((error as? CoreError)?.code, .ownershipConflict) }
        XCTAssertEqual(try repo.activeSession()?.recoveryAttempts, 0)
        let status = await other.status()
        XCTAssertFalse(status.canApply)
        var intent = RestartIntent(sessionID: UUID(), baselineVersion: UUID(), sourceBootID: "a", expected: defaults, now: Date(timeIntervalSince1970: 1000), ownerUID: uid)
        intent.normalRestartObserved = true
        XCTAssertThrowsError(try intent.consume(targetBootID: "b", targetBootTime: Date(timeIntervalSince1970: 1100), uptime: 1, provenImmediateNextBoot: true, ownerUID: uid + 1))
        XCTAssertNil(intent.targetBootID)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testInspectionRereadsAfterTakingLockInsteadOfComparingAStaleRead() async throws {
        let (repo, adapter, engine) = try await setup()
        _ = try await engine.apply(profile: ny, confirmedActual: defaults)
        var next = try repo.activeSession()!
        next.lastKnownActual = try tokyo.applying(to: next.lastKnownActual)
        next.target = next.lastKnownActual
        await adapter.replaceSessionAfterNextRead(next)
        let inspected = try await engine.inspectActual()
        XCTAssertEqual(inspected, next.lastKnownActual)
        XCTAssertEqual(try repo.activeSession()?.state, .working)
        XCTAssertTrue(try repo.timezonePreparation().userConfirmed)
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testSlowFailureWaitsFullDelayAfterCompletionAndKeepsStartReservation() async throws {
        let start = Date(timeIntervalSince1970: 1000)
        let clock = ManualClock(start)
        let (repo, adapter, engine) = try await setup(clock: { clock.now() })
        _ = try await engine.apply(profile: ny, confirmedActual: defaults)
        await adapter.fail(.languages)
        await adapter.slowFailure(clock: clock, duration: 20)
        _ = try await engine.recover(now: start)
        let reservation = await adapter.ownershipRecoveryDueAt
        XCTAssertEqual(reservation, start.addingTimeInterval(5))
        XCTAssertEqual(try repo.activeSession()?.recoveryDueAt, start.addingTimeInterval(25))
        do { _ = try await engine.recover(now: start.addingTimeInterval(24)); XCTFail("Must wait after failure completion") } catch { XCTAssertEqual((error as? CoreError)?.code, .recoveryNotDue) }
        clock.advance(5)
        _ = try await engine.recover(now: start.addingTimeInterval(25))
        XCTAssertEqual(try repo.activeSession()?.recoveryDueAt, start.addingTimeInterval(75))
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testCanApplyRejectsEveryNonWorkingStateAndUnresolvedOperation() async throws {
        let (repo, _, engine) = try await setup()
        _ = try await engine.apply(profile: ny, confirmedActual: defaults)
        var session = try repo.activeSession()!
        for state in [SessionState.recovering, .waitingForRestart, .handoff, .needsAttention] {
            session.state = state; try repo.saveSession(session)
            let status = await engine.status(); XCTAssertFalse(status.canApply)
        }
        session.state = .working; try repo.saveSession(session)
        let unresolved = OperationRecord(sessionID: session.id, baselineVersion: session.baselineVersion, kind: .apply, title: "pending", before: session.lastKnownActual, target: session.target)
        try repo.saveOperation(unresolved)
        let status = await engine.status(); XCTAssertFalse(status.canApply)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testCorruptOperationShowsActualAndVerifiedBackupWithoutSystemWrites() async throws {
        let (repo, adapter, engine) = try await setup()
        _ = try await engine.apply(profile: ny, confirmedActual: defaults)
        let actual = try await adapter.read()
        let writes = await adapter.writes
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(repo.directory.appendingPathComponent("localeshift.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "UPDATE operations SET payload=CAST('broken' AS BLOB)", nil, nil, nil), SQLITE_OK)
        let status = await engine.status()
        XCTAssertEqual(status.error?.code, .dataCorrupt)
        XCTAssertEqual(status.actual, actual)
        XCTAssertNotNil(status.recoveryBackup)
        XCTAssertFalse(status.canApply)
        do { _ = try await engine.restore(confirmedActual: actual); XCTFail("Must verify corruption before restore") } catch { XCTAssertEqual((error as? CoreError)?.code, .dataCorrupt) }
        let finalWrites = await adapter.writes
        XCTAssertEqual(finalWrites, writes)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testDurablyRolledBackFieldCannotAuthorizeAnExternalReturnToTarget() async throws {
        let (repo, adapter, engine) = try await setup()
        let baseline = try repo.baseline()!
        let target = try ny.applying(to: defaults)
        var session = WorkSession(baselineVersion: baseline.version, process: process, target: target, targetTitle: ny.title, lastKnownActual: defaults, state: .needsAttention)
        session.error = CoreError(.transientUnavailable)
        var operation = OperationRecord(sessionID: session.id, baselineVersion: baseline.version, kind: .apply, title: ny.title, before: defaults, target: target)
        operation.state = .needsAttention
        operation.steps[0].state = .rolledBack
        operation.steps[0].readback = defaults
        operation.steps[1].state = .pending
        operation.steps[2].state = .rollbackIntentSaved
        try repo.commit(operation: operation, session: session)
        var external = defaults; external.languages = target.languages
        await adapter.changeExternally(external)
        do { _ = try await engine.recover(); XCTFail("Rolled-back target must be treated as external") } catch { XCTAssertEqual((error as? CoreError)?.code, .externalChange) }
        let writes = await adapter.writes; XCTAssertEqual(writes, [])
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testBoundRootTimezoneReceiptAcceptsBaselineDuringInterruptedContinuousSwitchOnlyForTimezone() async throws {
        for externalLanguage in [false, true] {
            let (repo, adapter, engine) = try await setup()
            let baseline = try repo.baseline()!
            let before = try ny.applying(to: defaults)
            let target = try tokyo.applying(to: before)
            var known = before; known.timeZone = defaults.timeZone
            var session = WorkSession(baselineVersion: baseline.version, process: process, target: target, targetTitle: tokyo.title, lastKnownActual: known, state: .needsAttention)
            session.timeZoneRecoveryReceipt = TimeZoneRecoveryReceipt(ownerUID: session.ownerUID, sessionID: session.id, baselineVersion: baseline.version, timeZone: defaults.timeZone)
            var interrupted = OperationRecord(sessionID: session.id, baselineVersion: baseline.version, kind: .apply, title: tokyo.title, before: before, target: target)
            interrupted.state = .executing
            interrupted.steps[0].state = .intentSaved
            interrupted.steps[1].state = .rolledBack
            interrupted.steps[2].state = .pending
            try repo.commit(operation: interrupted, session: session)
            var actual = known; actual.languages = externalLanguage ? ["fr"] : target.languages
            await adapter.changeExternally(actual)
            if externalLanguage {
                do { _ = try await engine.recover(); XCTFail("Timezone proof cannot authorize a language conflict") } catch { XCTAssertEqual((error as? CoreError)?.code, .externalChange) }
                let writes = await adapter.writes; XCTAssertEqual(writes, [])
            } else {
                let result = try await engine.recover(); XCTAssertTrue(result.succeeded)
                let final = try await adapter.read(); XCTAssertEqual(final, defaults)
            }
        }
    }

}
